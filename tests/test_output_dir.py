"""DEV-06: --output-dir destination folder (real FFmpeg, small fixtures)."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"
FFMPEG = shutil.which("ffmpeg")


def run(*args):
    completed = subprocess.run([str(CLI), *map(str, args)], capture_output=True, text=True)
    events = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    return completed.returncode, events


@unittest.skipUnless(FFMPEG and shutil.which("ffprobe"), "ffmpeg and ffprobe are required")
class OutputDirTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-outdir-")
        self.root = Path(self.tmp.name)
        self.source_dir = self.root / "Исходники [1] #2 100%"
        self.source_dir.mkdir()
        self.source = self.source_dir / "кадр 'a' \"b\".png"
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=96x64",
                        "-frames:v", "1", str(self.source)], check=True)

    def tearDown(self):
        for path in self.root.rglob("*"):
            if path.is_dir():
                path.chmod(0o755)
        self.tmp.cleanup()

    def test_output_dir_keeps_default_name(self):
        target = self.root / "Готово $(x) ;&"
        target.mkdir()
        code, events = run(self.source, "--format", "webp", "--preset", "balanced", "--output-dir", target)
        self.assertEqual(code, 0, events)
        result = Path(events[-1]["path"])
        self.assertEqual(result.parent, target.resolve())
        self.assertEqual(result.name, self.source.with_suffix(".webp").name)
        self.assertFalse(list(target.glob(".omaconvert-*")))
        self.assertFalse(self.source.with_suffix(".webp").exists(), "nothing written next to the source")

    def test_same_folder_and_format_never_replaces_source(self):
        before = self.source.read_bytes()
        code, events = run(self.source, "--format", "png", "--preset", "high", "--output-dir", self.source_dir)
        self.assertEqual(code, 0, events)
        result = Path(events[-1]["path"])
        self.assertNotEqual(result, self.source.resolve())
        self.assertTrue(result.name.endswith("-2.png"), result.name)
        self.assertEqual(self.source.read_bytes(), before)

    def test_read_only_folder_fails_before_encoding(self):
        locked = self.root / "locked"
        locked.mkdir()
        locked.chmod(0o555)
        if os.access(locked, os.W_OK):
            self.skipTest("running with privileges that ignore directory permissions")
        code, events = run(self.source, "--format", "webp", "--output-dir", locked)
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]["event"], "error")
        self.assertIn("not writable", events[-1]["message"])
        self.assertNotIn("encoding", [event["event"] for event in events])
        self.assertEqual(list(locked.iterdir()), [])

    def test_missing_folder_and_conflicting_flags(self):
        code, events = run(self.source, "--format", "webp", "--output-dir", self.root / "missing")
        self.assertEqual(code, 2)
        self.assertIn("does not exist", events[-1]["message"])
        code, events = run(self.source, "--format", "webp", "--output-dir", self.root,
                           "--output", self.root / "x.webp")
        self.assertEqual(code, 2)
        self.assertIn("either --output or --output-dir", events[-1]["message"])


if __name__ == "__main__":
    unittest.main()
