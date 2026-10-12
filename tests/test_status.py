"""--status answers everything the window asks when it opens in one event,
and FFmpeg's tables are cached on disk, keyed by the executable."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"
sys.path.insert(0, str(ROOT))

from lib import formats


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-status-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, XDG_CACHE_HOME=str(self.root / "cache"),
                        XDG_CONFIG_HOME=str(self.root / "config"),
                        XDG_DATA_HOME=str(self.root / "data"))

    def status(self, env):
        done = subprocess.run([str(CLI), "--status"], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return json.loads(done.stdout.splitlines()[-1])

    def test_one_event_with_every_part(self):
        event = self.status(self.env)
        self.assertEqual(event["event"], "status")
        self.assertEqual(event["version"], __import__("lib").__version__)
        if event["dependencies"]["ok"]:
            self.assertIn("formats", event["capabilities"])
        self.assertIn("enabled", event["open_with"])
        self.assertIn("enabled", event["hotkey"])

    def test_missing_ffmpeg_is_an_error_field_not_a_failure(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        python = bin_dir / "python3"
        python.symlink_to(sys.executable)
        env = dict(self.env, PATH=str(bin_dir))
        event = self.status(env)
        self.assertFalse(event["dependencies"]["ok"])
        self.assertIn("Install FFmpeg", event["error"]["message"])
        self.assertNotIn("capabilities", event)


class ToolboxDiskCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-toolbox-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.stub = self.root / "ffmpeg"
        self.write_stub("libx264")
        patcher = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.root / "cache")})
        patcher.start()
        self.addCleanup(patcher.stop)
        formats.clear_cache()
        self.addCleanup(formats.clear_cache)

    def write_stub(self, encoder):
        self.stub.write_text(
            "#!/bin/sh\n"
            'case "$2" in\n'
            f'  -encoders) printf " V..... {encoder} x\\n" ;;\n'
            '  -muxers) printf "  E mp4 x\\n" ;;\n'
            '  -filters) printf " ... scale V->V x\\n" ;;\n'
            "esac\n")
        self.stub.chmod(self.stub.stat().st_mode | stat.S_IXUSR)

    def test_second_process_reads_the_disk_and_a_changed_ffmpeg_is_asked_again(self):
        first = formats.toolbox(str(self.stub))
        self.assertIn("libx264", first.encoders)
        cache = self.root / "cache" / "omaconvert" / "toolbox.json"
        self.assertEqual(stat.S_IMODE(cache.stat().st_mode), 0o600)
        formats.clear_cache()
        with mock.patch.object(formats, "_run", side_effect=AssertionError("asked FFmpeg again")):
            self.assertEqual(formats.toolbox(str(self.stub)), first)
        formats.clear_cache()
        self.write_stub("libvpx-vp9")
        os.utime(self.stub, ns=(1, 1))
        self.assertIn("libvpx-vp9", formats.toolbox(str(self.stub)).encoders)


if __name__ == "__main__":
    unittest.main()
