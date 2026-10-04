"""Publishing on filesystems without hard links (FAT/exFAT USB drives, many
network and FUSE mounts): link(2) fails there with EPERM/ENOTSUP, which used
to fail the job after the whole encode. The fallbacks must keep the same
guarantees: never replace an existing file, and a cancel at the publish
boundary leaves nothing visible."""
import errno
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from lib import publish
from lib.errors import Cancelled


def no_hardlinks(*_args):
    raise OSError(errno.EPERM, "Operation not permitted")


def no_renameat2(*_args):
    raise OSError(errno.EINVAL, "Invalid argument")


class NoHardlinkPublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-publish-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.temp_output = self.root / ".omaconvert-x" / "result.gif"
        self.temp_output.parent.mkdir()
        self.temp_output.write_bytes(b"new result")
        (self.root / "clip.gif").write_bytes(b"older file")

    def publish(self, check_cancelled=None):
        return publish.publish_no_clobber(self.temp_output, self.root / "clip.gif",
                                          self.root / "clip.mp4", check_cancelled=check_cancelled)

    def cancel_on_second_check(self):
        calls = {"n": 0}

        def check():
            calls["n"] += 1
            if calls["n"] == 2:
                raise Cancelled("Conversion cancelled.")
        return check

    def assert_published_beside_existing(self, target):
        self.assertEqual(target, (self.root / "clip-2.gif").resolve())
        self.assertEqual(target.read_bytes(), b"new result")
        self.assertEqual((self.root / "clip.gif").read_bytes(), b"older file")
        self.assertFalse(self.temp_output.exists())

    def test_rename_fallback_never_replaces(self):
        with mock.patch("lib.publish.os.link", side_effect=no_hardlinks):
            self.assert_published_beside_existing(self.publish())

    def test_copy_fallback_never_replaces(self):
        with mock.patch("lib.publish.os.link", side_effect=no_hardlinks), \
             mock.patch("lib.publish._rename_noreplace", side_effect=no_renameat2):
            self.assert_published_beside_existing(self.publish())

    def test_cancel_after_rename_fallback_restores_temp(self):
        with mock.patch("lib.publish.os.link", side_effect=no_hardlinks):
            with self.assertRaises(Cancelled):
                self.publish(self.cancel_on_second_check())
        self.assertFalse((self.root / "clip-2.gif").exists())
        self.assertEqual(self.temp_output.read_bytes(), b"new result")

    def test_cancel_after_copy_fallback_removes_copy(self):
        with mock.patch("lib.publish.os.link", side_effect=no_hardlinks), \
             mock.patch("lib.publish._rename_noreplace", side_effect=no_renameat2):
            with self.assertRaises(Cancelled):
                self.publish(self.cancel_on_second_check())
        self.assertFalse((self.root / "clip-2.gif").exists())
        self.assertEqual(self.temp_output.read_bytes(), b"new result")

    def test_failed_copy_leaves_no_partial_file(self):
        with mock.patch("lib.publish.os.link", side_effect=no_hardlinks), \
             mock.patch("lib.publish._rename_noreplace", side_effect=no_renameat2), \
             mock.patch("lib.publish.shutil.copyfileobj", side_effect=OSError(errno.ENOSPC, "No space")):
            with self.assertRaises(OSError):
                self.publish()
        self.assertFalse((self.root / "clip-2.gif").exists())
        self.assertTrue(self.temp_output.exists())

    def test_unrelated_link_errors_still_fail(self):
        with mock.patch("lib.publish.os.link", side_effect=OSError(errno.EACCES, "Permission denied")):
            with self.assertRaises(PermissionError):
                self.publish()
        self.assertTrue(self.temp_output.exists())


if __name__ == "__main__":
    unittest.main()
