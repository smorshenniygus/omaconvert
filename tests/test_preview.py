import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from lib.errors import OmaConvertError
from lib.preview import clamp_edge, generate_preview, png_size, preview_position
from lib.probe import MediaInfo, probe_media
from lib.process import ProcessRunner


class Sink:
    def emit(self, *_args, **_fields):
        pass


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.runner = ProcessRunner(Sink())
        self.video = self.root / "clip [1] (тест).mp4"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=s=640x480:r=15:d=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", str(self.video),
        ], check=True)
        self.image = self.root / "прозрачная [2].png"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=red@0.35:s=800x600,format=rgba",
            "-frames:v", "1", str(self.image),
        ], check=True)

    def tearDown(self):
        self.directory.cleanup()

    def test_video_preview_is_bounded_and_seeks_inside(self):
        output = self.root / "video-preview.png"
        got = generate_preview(self.runner, self.video, output, max_edge=320)
        self.assertTrue(output.is_file())
        self.assertLessEqual(max(got["width"], got["height"]), 320)
        self.assertGreater(got["bytes"], 0)
        # 2s clip -> ~0.5s seek, never 0 and never past the end.
        self.assertGreater(got["seek"], 0)
        self.assertLess(got["seek"], 2.0)
        self.assertEqual(got["kind"], "video")

    def test_preview_size_comes_from_the_png_header(self):
        output = self.root / "header-preview.png"
        got = generate_preview(self.runner, self.video, output, max_edge=320)
        probed = probe_media(output, self.runner)
        self.assertEqual((got["width"], got["height"]), (probed.width, probed.height))
        not_png = self.root / "not.png"
        not_png.write_bytes(b"GIF89a" + bytes(40))
        with self.assertRaises(OmaConvertError):
            png_size(not_png)
        not_png.write_bytes(b"")
        with self.assertRaises(OmaConvertError):
            png_size(not_png)

    def test_image_preview_preserves_aspect_and_alpha(self):
        output = self.root / "image-preview.png"
        got = generate_preview(self.runner, self.image, output, max_edge=200)
        self.assertLessEqual(max(got["width"], got["height"]), 200)
        # 800x600 scaled to longest edge 200 -> 200x150.
        self.assertEqual((got["width"], got["height"]), (200, 150))
        probe = json.loads(subprocess.run([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=pix_fmt", "-of", "json", str(output),
        ], check=True, text=True, stdout=subprocess.PIPE).stdout)
        self.assertIn("a", probe["streams"][0]["pix_fmt"])

    def test_edge_is_clamped_independent_of_source(self):
        self.assertEqual(clamp_edge(9999), 640)
        self.assertEqual(clamp_edge(1), 64)
        self.assertEqual(clamp_edge("oops"), 320)
        output = self.root / "huge-preview.png"
        got = generate_preview(self.runner, self.image, output, max_edge=9999)
        self.assertLessEqual(max(got["width"], got["height"]), 640)

    def test_position_selection(self):
        info = MediaInfo("c.mp4", 8.0, 640, 480, 15.0, "h264", 1000, True)
        self.assertAlmostEqual(preview_position(info), 2.0)
        self.assertEqual(preview_position(MediaInfo("i.png", 0, 8, 8, 0, "png", 10, False)), None)
        self.assertEqual(preview_position(MediaInfo("c.mp4", 0, 8, 8, 5, "h264", 10, False)), None)
        with self.assertRaises(OmaConvertError):
            preview_position(info, requested=-1)

    def test_missing_input_is_a_clean_error(self):
        with self.assertRaises(OmaConvertError):
            generate_preview(self.runner, self.root / "nope.mp4",
                             self.root / "out.png")

    def test_cli_preview_event_is_json(self):
        output = self.root / "cli-preview.png"
        result = subprocess.run(
            [str(ROOT / "bin" / "omaconvert"), "--preview", str(self.video),
             "--preview-output", str(output), "--preview-size", "160"],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        preview = next(e for e in events if e.get("event") == "preview")
        self.assertLessEqual(max(preview["width"], preview["height"]), 160)
        self.assertTrue(Path(preview["path"]).is_file())
        self.assertEqual(result.stderr, "")

    def test_cli_preview_requires_output(self):
        result = subprocess.run(
            [str(ROOT / "bin" / "omaconvert"), "--preview", str(self.video)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)
        event = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(event["event"], "error")


if __name__ == "__main__":
    unittest.main()
