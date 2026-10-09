"""Thumbnails and results never expose a private source: the window's cached
previews are owner-only and can be deleted, and a converted file is never
readable by more people than the file it came from."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"
sys.path.insert(0, str(ROOT))

from lib.errors import OmaConvertError
from lib.preview import forget_preview


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class PrivacyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-privacy-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cache_home = self.root / "cache"
        self.source = self.root / "private.png"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                        "-i", "testsrc2=s=640x360", "-frames:v", "1", str(self.source)], check=True)
        self.source.chmod(0o600)
        self.previews = self.cache_home / "omaconvert" / "previews"

    def run_cli(self, *args, umask=0o022):
        env = dict(os.environ, XDG_CACHE_HOME=str(self.cache_home))
        done = subprocess.run([str(CLI), *map(str, args)], capture_output=True, text=True,
                              timeout=120, env=env, preexec_fn=lambda: os.umask(umask))
        return done.returncode, [json.loads(line) for line in done.stdout.splitlines() if line.strip()]

    def test_window_preview_is_owner_only_under_a_permissive_umask(self):
        target = self.previews / "src-preview.png"
        code, events = self.run_cli("--preview", self.source, "--preview-output", target)
        self.assertEqual(code, 0, events)
        self.assertEqual(mode(target), 0o600)
        self.assertEqual(mode(self.previews), 0o700)
        self.assertEqual(mode(self.previews.parent), 0o700)
        self.assertEqual(sorted(p.name for p in self.previews.iterdir()), ["src-preview.png"])

    def test_a_cache_left_open_by_an_older_version_is_tightened(self):
        self.previews.mkdir(parents=True)
        self.previews.chmod(0o755)
        self.previews.parent.chmod(0o755)
        old = self.previews / "src-preview.png"
        old.write_bytes(b"old thumbnail")
        old.chmod(0o644)
        code, events = self.run_cli("--preview", self.source, "--preview-output", old)
        self.assertEqual(code, 0, events)
        self.assertEqual(mode(old), 0o600)
        self.assertEqual(mode(self.previews), 0o700)
        self.assertEqual(mode(self.previews.parent), 0o700)

    def test_forget_deletes_the_cached_copy(self):
        target = self.previews / "res-preview.png"
        self.run_cli("--preview", self.source, "--preview-output", target)
        (self.previews / ".res-preview.png.abc.tmp.png").write_bytes(b"half written")
        code, events = self.run_cli("--forget-preview", target)
        self.assertEqual(code, 0, events)
        self.assertEqual(events[-1], {"event": "forgotten", "path": str(target), "removed": True})
        self.assertEqual(list(self.previews.iterdir()), [])
        code, events = self.run_cli("--forget-preview", target)
        self.assertEqual((code, events[-1]["removed"]), (0, False))

    def test_forget_refuses_any_other_file(self):
        with self.assertRaises(OmaConvertError):
            forget_preview(self.source)
        self.assertTrue(self.source.is_file())
        code, events = self.run_cli("--forget-preview", self.source)
        self.assertNotEqual(code, 0)
        self.assertTrue(self.source.is_file())

    def test_result_of_a_private_source_stays_private(self):
        code, events = self.run_cli(self.source, "--format", "jpg", "--max-size", "60KB")
        self.assertEqual(code, 0, events)
        self.assertEqual(mode(events[-1]["path"]) & 0o077, 0)

    def test_result_of_a_shared_source_keeps_normal_permissions(self):
        self.source.chmod(0o644)
        code, events = self.run_cli(self.source, "--format", "jpg", "--max-size", "60KB")
        self.assertEqual(code, 0, events)
        self.assertEqual(mode(events[-1]["path"]), 0o644)

    def test_private_frame_sequence_folder_stays_private(self):
        video = self.root / "private.mp4"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                        "-i", "testsrc2=s=320x240:r=10:d=1", "-pix_fmt", "yuv420p", str(video)], check=True)
        video.chmod(0o600)
        code, events = self.run_cli(video, "--format", "png", "--sequence", "--sequence-fps", "5")
        self.assertEqual(code, 0, events)
        folder = Path(events[-1]["path"])
        self.assertEqual(mode(folder) & 0o077, 0)
        self.assertTrue(all(mode(p) & 0o077 == 0 for p in folder.iterdir()))


if __name__ == "__main__":
    unittest.main()
