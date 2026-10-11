import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from lib.backend import _resolve_trim, convert
from lib.errors import OmaConvertError
from lib.probe import MediaInfo, probe_media
from lib.process import ProcessRunner


class Sink:
    def emit(self, *_args, **_fields):
        pass


def media_duration(path, runner):
    from pathlib import Path as P
    info = probe_media(P(path), runner)
    return info.duration


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class TrimTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.runner = ProcessRunner(Sink())
        self.video = self.root / "story [ Connor ].mp4"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=s=320x180:r=15:d=10",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-shortest", str(self.video),
        ], check=True)

    def tearDown(self):
        self.directory.cleanup()

    def probe_duration(self, path):
        raw = subprocess.run([
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "json", str(path),
        ], check=True, text=True, stdout=subprocess.PIPE).stdout
        return float(json.loads(raw)["format"]["duration"])

    def test_trimmed_mp4_matches_interval_and_keeps_audio(self):
        out = self.root / "trim.mp4"
        result = convert(self.runner, self.video, "mp4", out, None, "small", "balanced", 2.0, 4.0)
        self.assertAlmostEqual(self.probe_duration(out), 2.0, delta=0.4)
        self.assertEqual(result["trim_start"], 2.0)
        self.assertEqual(result["trim_end"], 4.0)
        streams = json.loads(subprocess.run([
            "ffprobe", "-v", "error", "-show_entries", "stream=codec_type",
            "-of", "json", str(out),
        ], check=True, text=True, stdout=subprocess.PIPE).stdout)["streams"]
        kinds = {s["codec_type"] for s in streams}
        self.assertIn("audio", kinds)
        # Audio stays in sync: durations of both streams stay close.
        per_stream = json.loads(subprocess.run([
            "ffprobe", "-v", "error", "-show_entries", "stream=codec_type,duration",
            "-of", "json", str(out),
        ], check=True, text=True, stdout=subprocess.PIPE).stdout)["streams"]
        durations = [float(s["duration"]) for s in per_stream if "duration" in s]
        self.assertTrue(durations)
        self.assertLess(max(durations) - min(durations), 0.5)

    def test_transport_stream_nonzero_trim_all_encoding_paths(self):
        source = self.root / "renamed-transport.mp4"  # Container, not extension, controls seeking.
        subprocess.run([
            "ffmpeg", "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=s=160x90:r=10:d=5", "-f", "lavfi", "-i",
            "sine=frequency=440:duration=5", "-c:v", "libx264", "-g", "250",
            "-c:a", "aac", "-shortest", "-f", "mpegts", str(source),
        ], check=True)
        expected = self.root / "expected.png"
        subprocess.run([
            "ffmpeg", "-v", "error", "-i", str(source), "-ss", "0.5",
            "-frames:v", "1", str(expected),
        ], check=True)

        def pixels(path):
            return subprocess.check_output([
                "ffmpeg", "-v", "error", "-i", str(path),
                "-pix_fmt", "rgb24", "-f", "rawvideo", "-",
            ])

        for fmt, target, sequence, end in [
            ("mp4", None, False, 1.5), ("mp4", 100_000, False, 1.5),
            ("gif", None, False, 1.5), ("gif", 400_000, False, 4.5),
            ("png", None, False, 1.5), ("png", None, True, 1.5),
        ]:
            with self.subTest(fmt=fmt, target=target, sequence=sequence):
                result = convert(ProcessRunner(Sink()), source, fmt, None, target,
                                 "high", "balanced", 0.5, end, sequence=sequence)
                if sequence:
                    self.assertEqual(result["frames"], 10)
                    self.assertEqual(pixels(result["first_frame"]), pixels(expected))
                elif fmt == "png":
                    self.assertEqual((result["width"], result["height"]), (160, 90))
                    self.assertEqual(pixels(result["path"]), pixels(expected))
                else:
                    self.assertAlmostEqual(self.probe_duration(result["path"]), end - 0.5, delta=0.2)
                if fmt == "mp4":
                    streams = json.loads(subprocess.check_output([
                        "ffprobe", "-v", "error", "-show_streams", "-of", "json", result["path"],
                    ]))["streams"]
                    self.assertEqual({stream["codec_type"] for stream in streams}, {"video", "audio"})
                    self.assertLess(max(float(stream["duration"]) for stream in streams)
                                    - min(float(stream["duration"]) for stream in streams), 0.15)

    def test_transport_trim_preserves_delayed_audio_start(self):
        source = self.root / "delayed.ts"
        subprocess.run([
            "ffmpeg", "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=s=160x90:r=10:d=3", "-itsoffset", "1", "-f", "lavfi", "-i",
            "sine=frequency=440:duration=2", "-c:v", "libx264", "-g", "250",
            "-c:a", "aac", "-f", "mpegts", str(source),
        ], check=True)
        result = convert(self.runner, source, "mp4", None, None,
                         "high", "balanced", 0.5, 1.5)
        streams = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_streams", "-of", "json", result["path"],
        ]))["streams"]
        starts = {stream["codec_type"]: float(stream["start_time"]) for stream in streams}
        self.assertAlmostEqual(starts["audio"] - starts["video"], 0.5, delta=0.1)
        self.assertAlmostEqual(self.probe_duration(result["path"]), 1.0, delta=0.15)

    def test_transport_trim_to_jpeg_keeps_foreground_first_frame(self):
        source = self.root / "red.ts"
        subprocess.run([
            "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=red:s=160x90:r=10:d=2",
            "-c:v", "libx264", "-f", "mpegts", str(source),
        ], check=True)
        result = convert(self.runner, source, "jpg", None, None,
                         "high", "balanced", 0.55, 1.55)
        pixel = subprocess.check_output([
            "ffmpeg", "-v", "error", "-i", result["path"],
            "-pix_fmt", "rgb24", "-f", "rawvideo", "-",
        ])[:3]
        self.assertGreater(pixel[0], 200)
        self.assertLess(pixel[1], 40)
        self.assertLess(pixel[2], 40)

    def test_fractional_boundaries(self):
        out = self.root / "frac.mp4"
        convert(self.runner, self.video, "mp4", out, None, "small", "balanced", 2.5, 3.7)
        self.assertAlmostEqual(self.probe_duration(out), 1.2, delta=0.4)

    def test_trim_makes_impossible_limit_possible(self):
        # Full 10s cannot fit into 60KB, but a 1s fragment can.
        out = self.root / "tiny.mp4"
        result = convert(self.runner, self.video, "mp4", out, 60_000, "balanced", "balanced", 1.0, 2.0)
        self.assertLessEqual(Path(result["path"]).stat().st_size, 60_000)

    def test_trimmed_gif_stays_within_limit(self):
        out = self.root / "trim.gif"
        result = convert(self.runner, self.video, "gif", out, 400_000, "balanced", "motion", 0.0, 2.0)
        self.assertLessEqual(Path(result["path"]).stat().st_size, 400_000)

    def test_still_uses_trim_start_frame(self):
        first = self.root / "first.png"
        convert(self.runner, self.video, "png", first, None, "high", "balanced")
        at_five = self.root / "at-five.png"
        convert(self.runner, self.video, "png", at_five, None, "high", "balanced", 5.0, 6.0)
        # testsrc2 changes over time: frames must differ.
        self.assertNotEqual(first.read_bytes(), at_five.read_bytes())

    def test_invalid_intervals_are_clean_errors(self):
        cases = [
            (5.0, 2.0, "end must be later"),
            (-1.0, 3.0, "zero or later"),
            (11.0, 12.0, "beyond the end"),
            (2.0, 2.0, "later than trim start"),
            (2.0, 2.05, "too short"),
            ("oops", 3.0, "number of seconds"),
        ]
        for start, end, message in cases:
            with self.subTest(start=start, end=end):
                out = self.root / "bad.mp4"
                with self.assertRaises(OmaConvertError) as caught:
                    convert(self.runner, self.video, "mp4", out, None, "small", "balanced", start, end)
                self.assertIn(message, caught.exception.message.lower())
                self.assertFalse(out.exists())

    def test_end_past_duration_clamps(self):
        out = self.root / "clamp.mp4"
        result = convert(self.runner, self.video, "mp4", out, None, "small", "balanced", 8.0, 99.0)
        self.assertAlmostEqual(result["trim_end"], 10.0, delta=0.2)
        self.assertAlmostEqual(self.probe_duration(out), 2.0, delta=0.4)

    def test_trim_rejected_for_images_and_unknown_duration(self):
        png = self.root / "pic.png"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=red:s=64x64,format=rgba",
            "-frames:v", "1", str(png),
        ], check=True)
        with self.assertRaises(OmaConvertError) as caught:
            convert(self.runner, png, "jpg", self.root / "o.jpg", None, "balanced", "balanced", 0.0, 1.0)
        self.assertIn("still images", caught.exception.message.lower())
        info = MediaInfo("anim.webp", 0.0, 64, 64, 5.0, "webp_anim", 100, False)
        with self.assertRaises(OmaConvertError):
            _resolve_trim(info, 0.0, 1.0)

    def test_cli_accepts_and_validates_trim_flags(self):
        out = self.root / "cli.mp4"
        result = subprocess.run(
            [str(ROOT / "bin" / "omaconvert"), str(self.video), "--format", "mp4",
             "--preset", "small", "--trim-start", "1", "--trim-end", "3",
             "--output", str(out)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        event = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(event["event"], "complete")
        self.assertAlmostEqual(event["trim_end"] - event["trim_start"], 2.0, delta=0.01)
        bad = subprocess.run(
            [str(ROOT / "bin" / "omaconvert"), str(self.video), "--format", "mp4",
             "--trim-start", "nope", "--output", str(self.root / "x.mp4")],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertNotEqual(bad.returncode, 0)
        self.assertEqual(json.loads(bad.stdout.splitlines()[-1])["event"], "error")


if __name__ == "__main__":
    unittest.main()
