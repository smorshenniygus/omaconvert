"""Batch: several inputs, one recipe. Files are converted one by one; a bad
file is reported and skipped, the rest still finish; the final event sums
up sizes. --probe-all describes every input before the user commits."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class BatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-batch-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.images = []
        for index, color in enumerate(("red", "green", "blue")):
            path = self.root / f"фото {index} [x].png"
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                            "-i", f"testsrc2=s=640x360,drawbox=c={color}@0.3:t=fill", "-frames:v", "1",
                            str(path)], check=True)
            self.images.append(path)
        self.broken = self.root / "broken.png"
        self.broken.write_bytes(b"not an image at all")

    def run_cli(self, *args):
        done = subprocess.run([str(CLI), *map(str, args)], capture_output=True, text=True, timeout=120)
        return done.returncode, [json.loads(line) for line in done.stdout.splitlines() if line.strip()]

    def test_batch_converts_each_file_and_skips_a_broken_one(self):
        inputs = [self.images[0], self.broken, self.images[1], self.images[2]]
        code, events = self.run_cli(*inputs, "--format", "jpg", "--max-size", "40KB")
        self.assertEqual(code, 0)
        items = [e for e in events if e["event"] == "item"]
        self.assertEqual([e["index"] for e in items], [0, 1, 2, 3])
        self.assertTrue(all(e["total"] == 4 for e in items))
        done = [e for e in events if e["event"] == "item-complete"]
        failed = [e for e in events if e["event"] == "item-error"]
        self.assertEqual(len(done), 3)
        self.assertEqual([e["source"] for e in failed], [str(self.broken)])
        for event in done:
            output = Path(event["path"])
            self.assertTrue(output.is_file())
            self.assertLessEqual(output.stat().st_size, 40_000)
            self.assertEqual(output.suffix, ".jpg")
        summary = events[-1]
        self.assertEqual(summary["event"], "batch-complete")
        self.assertEqual((summary["done"], summary["failed"], summary["total"]), (3, 1, 4))
        self.assertEqual(summary["bytes_after"], sum(e["bytes"] for e in done))
        self.assertEqual(summary["bytes_before"], sum(p.stat().st_size for p in self.images))
        self.assertFalse(any(e["event"] == "complete" for e in events))
        for image in self.images:
            self.assertTrue(image.is_file(), "sources stay untouched")

    def test_batch_honours_the_output_folder(self):
        out = self.root / "out"
        out.mkdir()
        code, events = self.run_cli(*self.images[:2], "--format", "webp", "--preset", "small", "--output-dir", out)
        self.assertEqual(code, 0)
        self.assertEqual(sorted(p.suffix for p in out.iterdir()), [".webp", ".webp"])

    def test_batch_where_nothing_converts_is_an_error(self):
        code, events = self.run_cli(self.broken, self.root / "missing.png", "--format", "jpg")
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]["event"], "error")

    def test_output_is_refused_for_several_inputs(self):
        code, events = self.run_cli(*self.images[:2], "--format", "jpg", "--output", self.root / "x.jpg")
        self.assertEqual(code, 2)
        self.assertIn("--output-dir", events[-1]["message"])

    def test_probe_all_describes_every_input(self):
        code, events = self.run_cli("--probe-all", self.images[0], self.broken, self.images[1])
        self.assertEqual(code, 0)
        items = [e for e in events if e["event"] == "probe-item"]
        self.assertEqual([e["index"] for e in items], [0, 1, 2])
        self.assertEqual([e["ok"] for e in items], [True, False, True])
        self.assertEqual(items[0]["kind"], "image")
        self.assertEqual(items[0]["path"], str(self.images[0].resolve()))
        self.assertTrue(items[1]["message"])

    def test_batch_of_one_reports_batch_events(self):
        # A selection where only one file is readable is still a batch for the window.
        code, events = self.run_cli(self.images[0], "--format", "jpg", "--max-size", "40KB", "--batch")
        self.assertEqual(code, 0, events)
        self.assertEqual([e["event"] for e in events if e["event"].startswith("item")], ["item", "item-complete"])
        summary = events[-1]
        self.assertEqual(summary["event"], "batch-complete")
        self.assertEqual((summary["done"], summary["total"]), (1, 1))
        self.assertEqual(len(summary["paths"]), 1)
        self.assertFalse(any(e["event"] == "complete" for e in events))
        code, events = self.run_cli(self.images[0], "--format", "jpg", "--batch", "--output", self.root / "x.jpg")
        self.assertEqual(code, 2)
        self.assertIn("--output-dir", events[-1]["message"])

    def test_single_input_still_reports_complete(self):
        code, events = self.run_cli(self.images[0], "--format", "jpg", "--max-size", "40KB")
        self.assertEqual(code, 0)
        self.assertEqual(events[-1]["event"], "complete")


if __name__ == "__main__":
    unittest.main()
