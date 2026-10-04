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
