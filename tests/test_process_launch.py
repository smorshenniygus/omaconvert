"""Media tools start through bin/omaconvert-exec: no Python callback runs
between fork and exec in the multithreaded backend (Python documents that as
able to deadlock), yet the tool still dies with the backend and a cancelled
job still stops its whole process group."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from lib.errors import OmaConvertError, ProcessFailed
from lib.events import EventSink
from lib.process import ProcessRunner, _through_helper

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bin" / "omaconvert-exec"


def alive(pid):
    """Running, not a zombie waiting for a reaper (none in some containers)."""
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return False
    return state not in ("Z", "X")


def running_with(marker):
    """Pids of live processes that have `marker` among their arguments."""
    found = []
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit() and entry.name != str(os.getpid()):
            try:
                arguments = (entry / "cmdline").read_bytes().split(b"\0")
            except OSError:
                continue
            if marker.encode() in arguments and alive(int(entry.name)):
                found.append(int(entry.name))
    return found


def wait_for(predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


class LaunchTests(unittest.TestCase):
    def test_launch_does_not_run_python_between_fork_and_exec(self):
        calls = []
        real = subprocess.Popen

        def spy(*args, **kwargs):
            calls.append(kwargs)
            return real(*args, **kwargs)

        with mock.patch.object(subprocess, "Popen", spy):
            ProcessRunner(EventSink()).capture(["true"], "true failed")
        self.assertEqual(len(calls), 1)
        self.assertIsNone(calls[0].get("preexec_fn"))
        self.assertTrue(calls[0]["start_new_session"], "cancelling signals the tool's own process group")

    def test_arguments_and_streams_reach_the_tool_unchanged(self):
        awkward = ["-x", "two words", "", "line\nbreak", "--", "ünï"]
        out = ProcessRunner(EventSink()).capture(
            [sys.executable, "-c", "import sys; print(repr(sys.argv[1:]))", *awkward], "tool failed")
        self.assertEqual(out.strip(), repr(awkward))

    def test_tool_keeps_default_signal_dispositions(self):
        # The helper is Python, which ignores SIGPIPE and SIGXFSZ for itself;
        # a tool that inherited that would see broken pipes as write errors.
        out = ProcessRunner(EventSink()).capture(["sh", "-c", "grep SigIgn /proc/self/status"], "tool failed")
        ignored = int(out.split()[1], 16)
        for number in (signal.SIGPIPE, signal.SIGXFSZ):
            self.assertFalse(ignored & (1 << (number - 1)), f"{signal.Signals(number).name} is ignored")

    def test_a_missing_tool_is_reported_as_one(self):
        with self.assertRaises(ProcessFailed) as caught:
            ProcessRunner(EventSink()).capture(["omaconvert-no-such-tool", "-x"], "tool failed")
        self.assertEqual(caught.exception.message, "Could not start a required media tool.")
        self.assertIn("omaconvert-no-such-tool", caught.exception.details)

    def test_helper_diagnostics_go_to_stderr_with_status_127(self):
        done = subprocess.run(_through_helper(["omaconvert-no-such-tool"]), capture_output=True, text=True)
        self.assertEqual(done.returncode, 127)
        self.assertEqual(done.stdout, "")
        self.assertTrue(done.stderr.startswith("omaconvert-exec: cannot start"), done.stderr)

    def test_helper_refuses_to_run_a_tool_for_a_backend_that_is_gone(self):
        gone = subprocess.Popen(["true"])
        gone.wait()
        with tempfile.TemporaryDirectory(prefix="omaconvert-launch-") as folder:
            marker = Path(folder) / "ran"
            done = subprocess.run(
                [sys.executable, "-I", "-S", "-B", str(HELPER), str(gone.pid),
                 "sh", "-c", 'echo > "$0"', str(marker)],
                capture_output=True, text=True)
            self.assertEqual(done.returncode, -signal.SIGKILL, done.stderr)
            self.assertFalse(marker.exists(), "the tool ran for a dead backend")

    def test_helper_rejects_a_malformed_command_line(self):
        for arguments in ([], ["notapid", "true"], ["123"]):
            with self.subTest(arguments=arguments):
                done = subprocess.run([sys.executable, "-I", "-S", "-B", str(HELPER), *arguments],
                                      capture_output=True, text=True)
                self.assertEqual(done.returncode, 2)
                self.assertIn("usage", done.stderr)


class ThreadedLaunchTests(unittest.TestCase):
    def test_concurrent_launches_all_complete(self):
        # The hazard of preexec_fn: a thread forks while another holds a lock
        # the child then needs. Launch from many threads at once, with others
        # busy allocating, and require every launch to finish in bounded time.
        runner = ProcessRunner(EventSink())
        workers, rounds = 24, 4
        start = threading.Barrier(workers + 1)
        results, stop = [], threading.Event()

        def launch():
            start.wait()
            try:
                for _ in range(rounds):
                    results.append(runner.capture(["echo", "ok"], "echo failed").strip())
            except Exception as exc:  # reported by the assertions below
                results.append(exc)

        def churn():
            while not stop.is_set():
                _ = [bytearray(1000) for _ in range(200)]

        threads = [threading.Thread(target=launch) for _ in range(workers)]
        noise = [threading.Thread(target=churn) for _ in range(4)]
        for thread in threads + noise:
            thread.start()
        start.wait()
        deadline = time.monotonic() + 60
        for thread in threads:
            thread.join(max(0.0, deadline - time.monotonic()))
        stop.set()
        for thread in noise:
            thread.join(5)
        self.assertFalse([t for t in threads if t.is_alive()], "launches did not finish in time")
        self.assertEqual(results, ["ok"] * (workers * rounds))

    def test_tool_lives_as_long_as_the_thread_that_started_it(self):
        # Linux ties the death signal to the thread that created the child
        # (see lib/process.py): other threads coming and going change nothing.
        runner = ProcessRunner(EventSink())
        outcome = []
        worker = threading.Thread(target=lambda: outcome.append(
            runner.capture([sys.executable, "-c", "import time; time.sleep(1.0); print('done')"], "tool failed")))
        worker.start()
        for _ in range(20):
            short = threading.Thread(target=runner.capture, args=(["true"], "true failed"))
            short.start()
            short.join()
        worker.join(15)
        self.assertEqual([text.strip() for text in outcome], ["done"])

    def test_a_tool_started_by_a_thread_that_exits_is_killed(self):
        # The reason the rule above exists. Pinned so a change in the platform
        # behaviour shows up here instead of as batch files failing.
        marker = f"omaconvert-thread-{os.getpid()}"
        started = []

        def start_then_exit():
            process = subprocess.Popen(
                _through_helper([sys.executable, "-c", "import time; time.sleep(30)", marker]),
                stdin=subprocess.DEVNULL, start_new_session=True)
            started.append(process)
            # Leave once the helper has armed the signal and become the tool.
            wait_for(lambda: running_with(marker) and b"omaconvert-exec" not in
                     Path(f"/proc/{process.pid}/cmdline").read_bytes())

        thread = threading.Thread(target=start_then_exit)
        thread.start()
        thread.join()
        process = started[0]
        self.addCleanup(lambda: (process.kill(), process.wait()))
        self.assertEqual(process.wait(timeout=10), -signal.SIGKILL)
        self.assertEqual(running_with(marker), [])


class KilledDuringStartupTests(unittest.TestCase):
    def test_no_encoder_survives_a_backend_killed_at_any_point_of_the_launch(self):
        # The backend dies while the helper is starting, arming the signal or
        # already running the tool. Whichever it is, nothing may keep running.
        with tempfile.TemporaryDirectory(prefix="omaconvert-startup-") as folder:
            leftovers = []
            for step in range(30):
                marker = f"omaconvert-startup-{os.getpid()}-{step}"
                backend = subprocess.Popen(
                    [sys.executable, "-B", "-c",
                     f"import sys; sys.path.insert(0, {str(ROOT)!r})\n"
                     "from lib.events import EventSink\n"
                     "from lib.process import ProcessRunner\n"
                     "print('go', flush=True)\n"
                     "ProcessRunner(EventSink()).capture("
                     f"[sys.executable, '-c', 'import time; time.sleep(30)', {marker!r}], 'tool failed')\n"],
                    stdout=subprocess.PIPE, text=True, cwd=folder)
                try:
                    self.assertEqual(backend.stdout.readline().strip(), "go")
                    time.sleep(step * 0.004)
                finally:
                    backend.kill()
                    backend.wait()
                    backend.stdout.close()
                if not wait_for(lambda: not running_with(marker)):
                    leftovers.append((step, running_with(marker)))
                    for pid in running_with(marker):
                        os.kill(pid, signal.SIGKILL)
        self.assertEqual(leftovers, [], "a media tool outlived the killed backend")


class CancellationTests(unittest.TestCase):
    def test_cancel_stops_the_tool_and_its_children(self):
        runner = ProcessRunner(EventSink())
        marker = f"omaconvert-cancel-{os.getpid()}"
        script = ("import subprocess, sys, time\n"
                  "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)', sys.argv[1]])\n"
                  "time.sleep(30)\n")
        outcome = []

        def run():
            try:
                runner.capture([sys.executable, "-c", script, marker], "tool failed")
            except OmaConvertError as exc:
                outcome.append(exc)

        worker = threading.Thread(target=run)
        worker.start()
        self.assertTrue(wait_for(lambda: len(running_with(marker)) >= 2, timeout=10))
        runner.cancel()
        worker.join(10)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(outcome), 1)
        self.assertTrue(wait_for(lambda: not running_with(marker)), "cancelling left a process running")


if __name__ == "__main__":
    unittest.main()
