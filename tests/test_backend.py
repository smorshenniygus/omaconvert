import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from lib.encoders import _video_shape, encode_video_quick, parse_ffmpeg_progress
from lib.backend import _convert_gif, _default_output, convert
from lib.errors import Cancelled, OmaConvertError
from lib.events import EventSink
from lib.optimizer import (
    build_gif_profiles,
    parse_size,
    representative_samples,
    size_text,
)
from lib.probe import parse_probe_json
from lib.probe import MediaInfo
from lib.process import ProcessRunner
from lib.publish import publish_no_clobber


class SizeTests(unittest.TestCase):
    def test_decimal_units_and_safety_margin(self):
        self.assertEqual(parse_size("50MB"), 50_000_000)
        self.assertEqual(parse_size("1.5 GB"), 1_500_000_000)

    def test_size_text_uses_the_unit_people_typed(self):
        self.assertEqual(size_text(200_000), "200 KB")
        self.assertEqual(size_text(50_000_000), "50 MB")
        self.assertEqual(size_text(1_500_000), "1.5 MB")
        self.assertEqual(size_text(2_000_000_000), "2 GB")

    def test_default_output_name_reads_like_the_target(self):
        source = Path("/media/photo.png")
        self.assertEqual(_default_output(source, "jpg", 200_000).name, "photo-200kb.jpg")
        self.assertEqual(_default_output(source, "gif", 50_000_000).name, "photo-50mb.gif")
        self.assertEqual(_default_output(source, "mp4", 1_500_000).name, "photo-1-5mb.mp4")
        self.assertEqual(_default_output(source, "webp", None).name, "photo.webp")

    def test_rejects_missing_nonpositive_and_unknown_units(self):
        for value in ("", "0MB", "-2 MB", "12MiB", "words"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_size(value)


class VideoShapeTests(unittest.TestCase):
    """Sizes measured with VMAF on real 1080p30 footage (x264 two-pass):
    the best output for a bitrate is the largest one that keeps ~0.055 bpp."""

    def info(self, width, height, fps=30.0):
        return MediaInfo(path="/clip.mp4", duration=10.0, width=width, height=height,
                         fps=fps, codec="h264", bytes=1, audio=True)

    def test_landscape_steps_down_by_short_side(self):
        clip = self.info(1920, 1080)
        self.assertEqual(_video_shape(clip, 400_000, 30.0), (640, 360))
        self.assertEqual(_video_shape(clip, 800_000, 30.0), (852, 480))
        self.assertEqual(_video_shape(clip, 3_100_000, 30.0), (1280, 720))
        self.assertEqual(_video_shape(clip, 4_600_000, 30.0), (1920, 1080))

    def test_portrait_phone_video_keeps_orientation(self):
        self.assertEqual(_video_shape(self.info(1080, 1920), 800_000, 30.0), (480, 852))

    def test_uses_output_frame_rate(self):
        # A 60 fps source is written at 30 fps: the same bits cover half the frames.
        self.assertEqual(_video_shape(self.info(1920, 1080, 60.0), 3_100_000, 30.0), (1280, 720))

    def test_never_upscales(self):
        self.assertEqual(_video_shape(self.info(640, 360), 50_000_000, 30.0), (640, 360))
        self.assertEqual(_video_shape(self.info(1920, 1080)), (1920, 1080))


class OptimizerTests(unittest.TestCase):
    def test_profiles_never_upscale_or_increase_fps_and_include_safe_minimum(self):
        profiles = build_gif_profiles(854, 480, 23.976, "balanced")
        self.assertTrue(profiles)
        self.assertTrue(all(p.width <= 854 and p.height <= 480 for p in profiles))
        self.assertTrue(all(p.fps <= 23.976 for p in profiles))
        self.assertEqual((profiles[-1].width, profiles[-1].fps, profiles[-1].colors), (320, 5.0, 32))
        self.assertTrue(all(p.width % 2 == 0 and p.height % 2 == 0 for p in profiles))

    def test_preference_changes_motion_detail_tradeoff(self):
        motion = build_gif_profiles(1920, 1080, 30, "motion")
        detail = build_gif_profiles(1920, 1080, 30, "detail")
        comparable = next(
            (m, d) for m, d in zip(motion[2:-1], detail[2:-1])
            if m.fps != d.fps and m.width != d.width
        )
        self.assertGreater(comparable[0].fps, comparable[1].fps)
        self.assertLess(comparable[0].width, comparable[1].width)

    def test_representative_samples_cover_long_video(self):
        samples = representative_samples(10.0)
        self.assertEqual(len(samples), 3)
        self.assertEqual(samples[0][0], 0.0)
        self.assertGreater(samples[1][0], 3.0)
        self.assertGreater(samples[2][0], 7.0)
        self.assertTrue(all(start + length <= 10.0 for start, length in samples))

    def test_short_video_uses_one_bounded_sample(self):
        self.assertEqual(representative_samples(0.4), [(0.0, 0.4)])


class ProbeTests(unittest.TestCase):
    def test_parses_video_audio_and_fractional_fps(self):
        raw = {
            "streams": [
                {"codec_type": "video", "codec_name": "h264", "width": 1920,
                 "height": 1080, "avg_frame_rate": "30000/1001", "r_frame_rate": "30/1"},
                {"codec_type": "audio", "codec_name": "aac"},
            ],
            "format": {"duration": "10.25", "size": "123456"},
        }
        got = parse_probe_json(raw, Path("clip.mp4"))
        self.assertEqual(got.width, 1920)
        self.assertEqual(got.height, 1080)
        self.assertAlmostEqual(got.fps, 29.97002997)
        self.assertEqual(got.codec, "h264")
        self.assertEqual(got.bytes, 123456)
        self.assertTrue(got.audio)

    def test_rejects_probe_without_video(self):
        with self.assertRaises(ValueError):
            parse_probe_json({"streams": [], "format": {}}, Path("bad.bin"))

    def test_ignores_attached_picture_and_normalizes_rotated_sar_without_upscaling(self):
        raw = {
            "streams": [
                {"index": 0, "codec_type": "video", "codec_name": "mjpeg",
                 "width": 600, "height": 600, "avg_frame_rate": "0/0",
                 "disposition": {"attached_pic": 1}},
                {"index": 1, "codec_type": "video", "codec_name": "h264",
                 "width": 1920, "height": 1080, "sample_aspect_ratio": "4:3",
                 "avg_frame_rate": "30/1", "side_data_list": [{"rotation": 90}],
                 "disposition": {"attached_pic": 0}},
            ],
            "format": {"duration": "5", "size": "1234"},
        }
        got = parse_probe_json(raw, Path("phone.mov"))
        self.assertEqual((got.width, got.height), (810, 1920))
        self.assertEqual(got.stream_index, 1)
        self.assertEqual(got.codec, "h264")

    def test_odd_rotated_dimensions_remain_within_source_canvas(self):
        raw = {
            "streams": [{"index": 2, "codec_type": "video", "codec_name": "h264",
                         "width": 321, "height": 241, "sample_aspect_ratio": "1:1",
                         "avg_frame_rate": "24/1", "tags": {"rotate": "-90"}}],
            "format": {"duration": "1", "size": "100"},
        }
        got = parse_probe_json(raw, Path("odd.mp4"))
        self.assertEqual((got.width, got.height), (241, 321))
        self.assertEqual(got.stream_index, 2)

    def test_accepts_single_frame_image_without_duration(self):
        raw = {
            "streams": [{"index": 0, "codec_type": "video", "codec_name": "png",
                         "width": 640, "height": 480, "avg_frame_rate": "25/1",
                         "nb_frames": "1", "pix_fmt": "rgba"}],
            "format": {"format_name": "png_pipe", "size": "3210"},
        }
        got = parse_probe_json(raw, Path("picture.data"))
        self.assertEqual(got.kind, "image")
        self.assertEqual(got.duration, 0)
        self.assertEqual(got.fps, 0)
        self.assertEqual((got.width, got.height), (640, 480))

    def test_animated_gif_is_not_misclassified_as_still_image(self):
        raw = {
            "streams": [{"index": 0, "codec_type": "video", "codec_name": "gif",
                         "width": 320, "height": 180, "avg_frame_rate": "10/1",
                         "nb_frames": "12"}],
            "format": {"format_name": "gif", "duration": "1.2", "size": "9000"},
        }
        got = parse_probe_json(raw, Path("animated.gif"))
        self.assertEqual(got.kind, "video")
        self.assertEqual(got.fps, 10)

    def test_animated_webp_derives_duration_from_frame_count(self):
        raw = {
            "streams": [{"index": 0, "codec_type": "video", "codec_name": "webp_anim",
                         "width": 64, "height": 64, "avg_frame_rate": "5/1",
                         "nb_read_frames": "5"}],
            "format": {"format_name": "webp_anim", "size": "6238"},
        }
        got = parse_probe_json(raw, Path("animated.webp"))
        self.assertEqual(got.kind, "video")
        self.assertEqual(got.duration, 1.0)

    def test_animated_webp_without_container_duration_is_kept_as_animation(self):
        raw = {
            "streams": [{"index": 0, "codec_type": "video", "codec_name": "webp_anim",
                         "width": 64, "height": 64, "avg_frame_rate": "5/1"}],
            "format": {"format_name": "webp_anim", "size": "6238"},
        }
        got = parse_probe_json(raw, Path("animated.webp"))
        self.assertEqual((got.kind, got.duration), ("video", 0.0))

    def test_accepts_one_pixel_image(self):
        raw = {
            "streams": [{"index": 0, "codec_type": "video", "codec_name": "png",
                         "width": 1, "height": 1, "nb_frames": "1"}],
            "format": {"format_name": "png_pipe", "size": "91"},
        }
        got = parse_probe_json(raw, Path("pixel.png"))
        self.assertEqual((got.width, got.height, got.kind), (1, 1, "image"))

    def test_one_frame_mp4_remains_video(self):
        raw = {
            "streams": [{"index": 0, "codec_type": "video", "codec_name": "h264",
                         "width": 320, "height": 180, "avg_frame_rate": "1/1",
                         "nb_frames": "1"}],
            "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2",
                       "duration": "1", "size": "2000"},
        }
        got = parse_probe_json(raw, Path("one-frame.mp4"))
        self.assertEqual(got.kind, "video")

    def test_avif_sequence_brand_is_not_flattened_to_still(self):
        raw = {
            "streams": [{"index": 0, "codec_type": "video", "codec_name": "av1",
                         "width": 320, "height": 180, "avg_frame_rate": "12/1"}],
            "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "size": "4000",
                       "tags": {"major_brand": "avis"}},
        }
        got = parse_probe_json(raw, Path("sequence.avif"))
        self.assertEqual((got.kind, got.duration), ("video", 0.0))


class ProgressTests(unittest.TestCase):
    def test_progress_is_fractional_and_clamped(self):
        self.assertEqual(parse_ffmpeg_progress("out_time_us=2500000", 10.0), 0.25)
        self.assertEqual(parse_ffmpeg_progress("out_time=00:00:20.000000", 10.0), 1.0)
        self.assertIsNone(parse_ffmpeg_progress("frame=12", 10.0))

    def test_encoding_events_use_public_pass_field(self):
        class RecordingSink:
            def __init__(self):
                self.events = []

            def emit(self, event, **fields):
                self.events.append({"event": event, **fields})

        class RecordingRunner:
            def __init__(self):
                self.sink = RecordingSink()
                self.ffmpeg_fields = None

            def ffmpeg(self, _args, _duration, **fields):
                self.args = _args
                self.ffmpeg_fields = fields

        runner = RecordingRunner()
        info = MediaInfo("clip.mp4", 3.0, 320, 180, 15.0, "h264", 1000, True)
        encode_video_quick(runner, Path("clip.mp4"), Path("out.mp4"), info, "mp4", "balanced")
        event = runner.sink.events[0]
        self.assertEqual(event["pass"], 1)
        self.assertNotIn("pass_", event)
        self.assertEqual(runner.ffmpeg_fields["pass"], 1)

    def test_video_encoder_maps_the_stream_selected_by_probe(self):
        class Runner:
            class Sink:
                def emit(self, *_args, **_fields):
                    pass

            def __init__(self):
                self.sink = self.Sink()
                self.args = None

            def ffmpeg(self, args, _duration, **_fields):
                self.args = args

        runner = Runner()
        info = MediaInfo("clip.mov", 3.0, 1080, 1920, 30.0, "h264", 1000, True, 2)
        width, height, _fps = encode_video_quick(
            runner, Path("clip.mov"), Path("out.mp4"), info, "mp4", "high"
        )
        map_at = runner.args.index("-map")
        self.assertEqual(runner.args[map_at + 1], "0:2")
        self.assertLessEqual(width, 1080)
        self.assertLessEqual(height, 1920)
        self.assertEqual(width % 2, 0)
        self.assertEqual(height % 2, 0)


class ProcessRunnerTests(unittest.TestCase):
    class Sink:
        def emit(self, *_args, **_fields):
            pass

    def test_cancellation_force_kills_tool_that_ignores_sigterm(self):
        runner = ProcessRunner(self.Sink())
        timer = threading.Timer(0.1, runner.cancel)
        timer.start()
        started = time.monotonic()
        try:
            with self.assertRaises(Cancelled):
                runner.capture(
                    [
                        sys.executable, "-c",
                        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
                    ],
                    "stubborn tool failed",
                )
        finally:
            timer.cancel()
        self.assertLess(time.monotonic() - started, 6)

    def test_failed_tool_retains_only_bounded_stderr_tail(self):
        runner = ProcessRunner(self.Sink())
        with self.assertRaises(OmaConvertError) as caught:
            runner.capture(
                [sys.executable, "-c", "import sys; sys.stderr.write('x' * 20000); sys.exit(1)"],
                "tool failed",
            )
        self.assertEqual(len(caught.exception.details), 8000)

    def test_capture_timeout_stops_hung_tool(self):
        runner = ProcessRunner(self.Sink())
        started = time.monotonic()
        with self.assertRaises(OmaConvertError) as caught:
            runner.capture([sys.executable, "-c", "import time; time.sleep(30)"],
                           "probe failed.", timeout=0.5)
        self.assertNotIsInstance(caught.exception, Cancelled)
        self.assertIn("stopped responding", caught.exception.message)
        self.assertLess(time.monotonic() - started, 6)

    def test_ffmpeg_stall_stops_encoder_without_progress(self):
        runner = ProcessRunner(self.Sink())
        script = ("import sys,time; print('out_time_us=1000000', flush=True); "
                  "time.sleep(30)")
        started = time.monotonic()
        with self.assertRaises(OmaConvertError) as caught:
            runner.ffmpeg([sys.executable, "-c", script], 10, stall=0.5)
        self.assertIn("stopped responding", caught.exception.message)
        self.assertLess(time.monotonic() - started, 6)

    def test_ffmpeg_advancing_progress_is_not_a_stall(self):
        runner = ProcessRunner(self.Sink())
        script = ("import time\n"
                  "for i in range(8):\n"
                  "    print(f'out_time_us={i * 100000}', flush=True); time.sleep(0.15)\n")
        runner.ffmpeg([sys.executable, "-c", script], 1, stall=0.5)

    def test_stall_timeout_env_override(self):
        from lib import process
        with mock.patch.dict(os.environ, {"OMACONVERT_STALL_TIMEOUT": "0"}):
            self.assertIsNone(process.stall_timeout())
        with mock.patch.dict(os.environ, {"OMACONVERT_STALL_TIMEOUT": "42"}):
            self.assertEqual(process.stall_timeout(), 42.0)
        with mock.patch.dict(os.environ, {"OMACONVERT_STALL_TIMEOUT": "junk"}):
            self.assertEqual(process.stall_timeout(), process.DEFAULT_STALL_TIMEOUT)


class TerminalMetadataTests(unittest.TestCase):
    def test_output_probe_failure_names_the_output_not_the_input(self):
        from lib import backend
        failure = OmaConvertError("Could not read the input media.", "moov atom not found")
        with mock.patch.object(backend, "probe_media", side_effect=failure):
            with self.assertRaises(OmaConvertError) as caught:
                backend._terminal_metadata("/tmp/result.mp4", runner=None)
        self.assertIn("converted file could not be verified", caught.exception.message)
        self.assertEqual(caught.exception.details, "moov atom not found")

    def test_output_probe_keeps_cancellation(self):
        from lib import backend
        with mock.patch.object(backend, "probe_media", side_effect=Cancelled("Conversion cancelled.")):
            with self.assertRaises(Cancelled):
                backend._terminal_metadata("/tmp/result.mp4", runner=None)


class PublicationTests(unittest.TestCase):
    def test_publication_preserves_existing_files_and_suffixes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requested = root / "movie.gif"
            requested.write_bytes(b"existing")
            temp_output = root / ".result.gif"
            temp_output.write_bytes(b"new")
            published = publish_no_clobber(temp_output, requested, forbidden=root / "movie.mp4")
            self.assertEqual(published.name, "movie-2.gif")
            self.assertEqual(requested.read_bytes(), b"existing")
            self.assertEqual(published.read_bytes(), b"new")
            self.assertFalse(temp_output.exists())

    def test_publication_never_replaces_input_even_if_requested(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "movie.mp4"
            source.write_bytes(b"source")
            temp_output = root / ".result.mp4"
            temp_output.write_bytes(b"new")
            published = publish_no_clobber(temp_output, source, forbidden=source)
            self.assertEqual(source.read_bytes(), b"source")
            self.assertEqual(published.name, "movie-2.mp4")


class ConversionSafetyTests(unittest.TestCase):
    class Sink:
        def emit(self, *_args, **_fields):
            pass

    class Runner:
        def __init__(self):
            self.sink = ConversionSafetyTests.Sink()
            self.cancelled = False

        def check_cancelled(self):
            if self.cancelled:
                raise Cancelled("Conversion cancelled.")

    def test_gif_higher_quality_retry_keeps_previous_fitting_file(self):
        profiles = build_gif_profiles(320, 180, 15, "balanced")[:3]
        runner = self.Runner()
        info = MediaInfo("source.mp4", 3.0, 320, 180, 15.0, "h264", 1000, True)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.gif"

            def fake_encode(_runner, _source, destination, profile, *_args, **_kwargs):
                size = {profiles[0]: 110, profiles[1]: 50, profiles[2]: 40}[profile]
                Path(destination).write_bytes(bytes([size]) * size)
                return size

            with mock.patch("lib.backend.build_gif_profiles", return_value=profiles), \
                 mock.patch("lib.backend._analyze_gif", return_value=(1, {})), \
                 mock.patch("lib.backend.encode_gif", side_effect=fake_encode):
                selected = _convert_gif(
                    runner, Path("source.mp4"), info, output, 100,
                    "balanced", directory, None,
                )

            self.assertEqual(selected, profiles[1])
            self.assertEqual(output.stat().st_size, 50)

    def test_failed_final_probe_does_not_publish_output(self):
        runner = self.Runner()
        info = MediaInfo("source.mp4", 3.0, 320, 180, 15.0, "h264", 1000, True)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.mp4"
            source.write_bytes(b"source")
            output = root / "result.mp4"

            def fake_encode(_runner, _source, destination, *_args):
                Path(destination).write_bytes(b"invalid")
                return 320, 180, 15.0

            with mock.patch("lib.backend.probe_media", side_effect=[info, OmaConvertError("bad output")]), \
                 mock.patch("lib.backend.encode_video_quick", side_effect=fake_encode):
                with self.assertRaises(OmaConvertError):
                    convert(runner, source, "mp4", output, None, "balanced", "balanced")

            self.assertFalse(output.exists())

    def test_publish_boundary_cancellation_removes_new_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            temp_output = root / ".result.gif"
            temp_output.write_bytes(b"complete")
            calls = 0

            def cancel_after_link():
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise Cancelled("Conversion cancelled.")

            with self.assertRaises(Cancelled):
                publish_no_clobber(
                    temp_output, root / "result.gif", root / "source.mp4",
                    check_cancelled=cancel_after_link,
                )
            self.assertFalse((root / "result.gif").exists())
            self.assertTrue(temp_output.exists())


class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(
            [str(ROOT / "bin" / "omaconvert"), *args],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_check_is_json_and_required_dependencies_are_available(self):
        result = self.run_cli("--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(lines[0]["event"], "dependencies")
        self.assertTrue(lines[0]["ffmpeg"])
        self.assertTrue(lines[0]["ffprobe"])
        self.assertEqual(result.stderr, "")

    def test_usage_errors_are_json_without_traceback(self):
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        event = events[-1]
        self.assertEqual(event["event"], "error")
        self.assertIn("input", event["message"].lower())
        self.assertNotIn("Traceback", result.stdout + result.stderr)

    def test_cli_accepts_expanded_output_formats(self):
        parser = __import__("lib.cli", fromlist=["build_parser"]).build_parser()
        for fmt in ("png", "jpg", "webp", "bmp", "tiff", "mov", "mkv"):
            with self.subTest(fmt=fmt):
                self.assertEqual(parser.parse_args(["input", "--format", fmt]).format, fmt)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class ImageConversionTests(unittest.TestCase):
    class Sink:
        def emit(self, *_args, **_fields):
            pass

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.runner = ProcessRunner(self.Sink())

    def tearDown(self):
        self.directory.cleanup()

    def make_rgba_png(self):
        source = self.root / "transparent source.png"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=red@0.35:s=512x384,format=rgba",
            "-frames:v", "1", str(source),
        ], check=True)
        return source

    def test_still_image_converts_to_all_still_formats(self):
        source = self.make_rgba_png()
        for fmt in ("png", "jpg", "webp", "bmp", "tiff", "gif"):
            with self.subTest(fmt=fmt):
                result = convert(self.runner, source, fmt, self.root / f"out.{fmt}",
                                 None, "high", "balanced")
                output = Path(result["path"])
                self.assertTrue(output.is_file())
                self.assertGreater(output.stat().st_size, 0)
                self.assertEqual((result["kind"], result["fps"]), ("image", 0.0))
                self.assertEqual(parse_probe_json(json.loads(subprocess.run([
                    "ffprobe", "-v", "error", "-show_streams", "-show_format",
                    "-of", "json", str(output),
                ], check=True, text=True, stdout=subprocess.PIPE).stdout), output).kind, "image")

    def test_image_target_limit_downscales_and_never_exceeds_cap(self):
        source = self.root / "noise.png"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "nullsrc=s=1200x900",
            "-vf", "geq=random(1)*255:128:random(2)*255", "-frames:v", "1", str(source),
        ], check=True)
        cap = 80_000
        result = convert(self.runner, source, "jpg", self.root / "small.jpg",
                         cap, "balanced", "balanced")
        output = Path(result["path"])
        self.assertLessEqual(output.stat().st_size, cap)
        self.assertLess(result["width"], 1200)

    def test_transparency_survives_png_and_webp(self):
        source = self.make_rgba_png()
        for fmt in ("png", "webp"):
            with self.subTest(fmt=fmt):
                result = convert(self.runner, source, fmt, self.root / f"alpha.{fmt}",
                                 None, "high", "balanced")
                probe = json.loads(subprocess.run([
                    "ffprobe", "-v", "error", "-select_streams", "v:0",
                    "-show_entries", "stream=pix_fmt", "-of", "json", result["path"],
                ], check=True, text=True, stdout=subprocess.PIPE).stdout)
                self.assertIn("a", probe["streams"][0]["pix_fmt"])

    def test_image_to_video_is_rejected_without_publishing(self):
        source = self.make_rgba_png()
        output = self.root / "wrong.mkv"
        with self.assertRaises(OmaConvertError) as caught:
            convert(self.runner, source, "mkv", output, None, "balanced", "balanced")
        self.assertIn("still image", caught.exception.message.lower())
        self.assertFalse(output.exists())

    def test_video_first_frame_and_mov_mkv_outputs(self):
        video = self.root / "input.mp4"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
            "-i", "testsrc2=s=320x180:r=12:d=0.5", "-c:v", "libx264", str(video),
        ], check=True)
        still = convert(self.runner, video, "png", self.root / "frame.png",
                        None, "high", "balanced")
        self.assertEqual((still["width"], still["height"]), (320, 180))
        for fmt in ("mov", "mkv"):
            with self.subTest(fmt=fmt):
                result = convert(self.runner, video, fmt, self.root / f"video.{fmt}",
                                 None, "small", "balanced")
                self.assertTrue(Path(result["path"]).is_file())


if __name__ == "__main__":
    unittest.main()
