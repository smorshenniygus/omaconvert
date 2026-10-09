"""The window kills the backend outright (SIGKILL) when the Omarchy shell
reloads mid-conversion. Its tools must not keep encoding on their own, and
the hidden working folder it leaves next to the user's files must be
cleaned by the next conversion into that folder, never while in use."""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from lib import publish

ROOT = Path(__file__).resolve().parents[1]


def alive(pid):
    """Running, not a zombie waiting for a reaper (none in some containers)."""
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return False
    return state not in ("Z", "X")


def wait_for(predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


class KilledBackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-killed-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def backend(self, code):
        """A Python backend running `code` with lib importable; killed at cleanup."""
        process = subprocess.Popen([sys.executable, "-c", f"import sys; sys.path.insert(0, {str(ROOT)!r})\n{code}"],
                                   stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (process.kill(), process.wait(), process.stdout.close()))
        return process

    def test_tools_die_with_the_backend(self):
        pid_file = self.root / "tool.pid"
        backend = self.backend(
            "from lib.events import EventSink\n"
            "from lib.process import ProcessRunner\n"
            "ProcessRunner(EventSink()).capture(['sh', '-c', 'echo $$ > \"$0\"; exec sleep 30', "
            f"{str(pid_file)!r}], 'test tool')\n")
        self.assertTrue(wait_for(lambda: pid_file.exists() and pid_file.read_text().strip()))
        tool = int(pid_file.read_text())
        self.assertTrue(alive(tool))
        backend.send_signal(signal.SIGKILL)
        backend.wait()
        self.assertTrue(wait_for(lambda: not alive(tool)), "the tool outlived the killed backend")

    def test_folder_of_a_killed_backend_is_removed_by_the_next_job(self):
        backend = self.backend(
            "import time\n"
            "from lib.publish import work_directory\n"
            f"with work_directory({str(self.root)!r}) as folder:\n"
            "    open(folder + '/partial.webm', 'w').write('half an encode')\n"
            "    print(folder, flush=True)\n"
            "    time.sleep(30)\n")
        left = Path(backend.stdout.readline().strip())
        self.assertTrue((left / "partial.webm").is_file())
        publish.remove_abandoned(self.root)
        self.assertTrue(left.is_dir(), "a folder in use must never be swept")
        backend.send_signal(signal.SIGKILL)
        backend.wait()
        self.assertTrue(left.is_dir(), "SIGKILL runs no cleanup")
        with publish.work_directory(self.root) as folder:
            self.assertFalse(left.exists(), "the abandoned folder is removed")
            self.assertTrue((Path(folder) / ".lock").is_file())
        self.assertEqual(list(self.root.iterdir()), [])

    def test_foreign_and_unlocked_folders_are_left_alone(self):
        older = self.root / ".omaconvert-older"  # an older version: no lock file
        older.mkdir()
        (older / "result.gif").write_bytes(b"x")
        held = self.root / ".omaconvert-held"
        held.mkdir()
        lock = os.open(held / ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        self.addCleanup(os.close, lock)
        fcntl.flock(lock, fcntl.LOCK_EX)
        unrelated = self.root / "photos"
        unrelated.mkdir()
        (unrelated / ".lock").write_text("")
        publish.remove_abandoned(self.root)
        self.assertTrue(older.is_dir() and held.is_dir() and unrelated.is_dir())

    def test_work_directory_cleans_up_after_errors(self):
        with self.assertRaises(RuntimeError):
            with publish.work_directory(self.root) as folder:
                Path(folder, "result.gif").write_bytes(b"x")
                raise RuntimeError("encode failed")
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
