import ctypes
import functools
import os
import shutil
import signal
import subprocess
import threading
import time

from .errors import Cancelled, ProcessFailed
from .tuning import DEFAULT_STALL_TIMEOUT, PROBE_TIMEOUT  # noqa: F401  (re-exported)


_PR_SET_PDEATHSIG = 1
try:
    _prctl = ctypes.CDLL(None, use_errno=True).prctl
    _prctl.argtypes = (ctypes.c_int,) + (ctypes.c_ulong,) * 4
except (OSError, AttributeError):
    _prctl = None


def _die_with_parent(parent):
    """Runs in the child before exec: SIGKILL it when the backend dies.

    The window kills the backend outright when the shell reloads. Tools run
    in their own session (for killpg) and FFmpeg ignores SIGPIPE, so they
    would otherwise keep encoding for minutes into a folder nobody cleans.
    Popen runs on the main thread, whose exit is what triggers the signal."""
    if _prctl is None:
        return
    _prctl(_PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0)
    if os.getppid() != parent:  # the backend died before prctl took effect
        os.kill(os.getpid(), signal.SIGKILL)


def dependencies():
    return {
        "ffmpeg": shutil.which("ffmpeg") is not None,
        "ffprobe": shutil.which("ffprobe") is not None,
        "gifsicle": shutil.which("gifsicle") is not None,
    }


def stall_timeout():
    raw = os.environ.get("OMACONVERT_STALL_TIMEOUT", "")
    try:
        value = float(raw) if raw else DEFAULT_STALL_TIMEOUT
    except ValueError:
        return DEFAULT_STALL_TIMEOUT
    return value if value > 0 else None


# -progress keys that change while an encode advances.
_ADVANCING = frozenset({"frame", "out_time_us", "out_time_ms", "out_time", "total_size", "progress"})


class ProcessRunner:
    def __init__(self, sink):
        self.sink = sink
        self.current = None
        self.cancelled = False
        self.signal_number = None
        self._lock = threading.RLock()
        self._terminators = {}
        self._timed_out = set()

    def check_cancelled(self):
        if self.cancelled:
            raise Cancelled("Conversion cancelled.")

    @staticmethod
    def _signal_group(process, signal_number):
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal_number)
            except ProcessLookupError:
                pass

    def _terminate(self, process):
        self._signal_group(process, signal.SIGTERM)

        # A stopped job's output is discarded, so FFmpeg gets only a short
        # grace: on SIGTERM it would finish the current frame first, which
        # takes seconds for a large still at maximum compression.
        def force_after_grace():
            deadline = time.monotonic() + 0.5
            while time.monotonic() < deadline:
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    return
                time.sleep(0.05)
            # The leader may have exited while a descendant kept the process
            # group alive, so address the group even when poll() is non-None.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

        with self._lock:
            if process in self._terminators:
                return
            thread = threading.Thread(target=force_after_grace, daemon=True)
            self._terminators[process] = thread
        thread.start()

    def cancel(self, signal_number=signal.SIGTERM):
        with self._lock:
            self.cancelled = True
            self.signal_number = signal_number
            process = self.current
        if process:
            self._terminate(process)

    def _start(self, args):
        self.check_cancelled()
        try:
            process = subprocess.Popen(
                args,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                errors="replace",
                start_new_session=True,
                preexec_fn=functools.partial(_die_with_parent, os.getpid()),
            )
        except OSError as exc:
            raise ProcessFailed("Could not start a required media tool.", str(exc)) from exc
        with self._lock:
            self.current = process
            cancelled = self.cancelled
        if cancelled:
            self._terminate(process)
        return process

    def _watch(self, process, limit, last_activity):
        """Stop `process` once `last_activity()` is older than `limit` seconds."""
        if not limit:
            return None

        def watchdog():
            while process.poll() is None:
                if time.monotonic() - last_activity() > limit:
                    with self._lock:
                        self._timed_out.add(process)
                    self._terminate(process)
                    return
                time.sleep(0.1)

        thread = threading.Thread(target=watchdog, daemon=True)
        thread.start()
        return thread

    def _finish(self, process, stderr, message):
        with self._lock:
            if self.current is process:
                self.current = None
            terminator = self._terminators.pop(process, None)
            timed_out = process in self._timed_out
            self._timed_out.discard(process)
        if terminator:
            terminator.join(timeout=4)
        if self.cancelled:
            raise Cancelled("Conversion cancelled.")
        if timed_out:
            details = (stderr or "").strip()[-8000:]
            raise ProcessFailed(message + " The media tool stopped responding and was stopped.",
                                details or "No output before the time limit.")
        if process.returncode:
            details = (stderr or "").strip()[-8000:]
            lowered = details.lower()
            if "no space left on device" in lowered:
                message = "Conversion failed because the destination disk is full."
            elif "permission denied" in lowered:
                message = "Conversion failed because the destination is not writable."
            raise ProcessFailed(message, details)

    def _run(self, args, message, limit, on_line=None):
        """Start `args`, keep a bounded stderr tail, stop the tool once nothing
        happened for `limit` seconds, and turn failures into errors.

        Without `on_line` stdout is collected and returned, and `limit`
        bounds the total wall time. With it every stdout line is passed on;
        a line for which it returns True counts as activity."""
        process = self._start(args)
        stderr_tail = _TailBuffer()
        thread = threading.Thread(target=_drain_tail, args=(process.stderr, stderr_tail), daemon=True)
        thread.start()
        activity = [time.monotonic()]
        self._watch(process, limit, lambda: activity[0])
        stdout = None
        if on_line is None:
            stdout = process.stdout.read()
        else:
            for line in process.stdout:
                if on_line(line.strip()):
                    activity[0] = time.monotonic()
        process.wait()
        thread.join()
        process.stdout.close()
        process.stderr.close()
        self._finish(process, stderr_tail.value, message)
        return stdout

    def capture(self, args, message, timeout=None):
        """Run a tool to completion; `timeout` bounds its total wall time."""
        return self._run(args, message, timeout)

    def ffmpeg(self, args, duration, stage="encoding", stall=None, **event_fields):
        """Run an FFmpeg encode with -progress; stop it if progress stalls."""
        from .encoders import parse_ffmpeg_progress
        seen = {}
        last_progress = [-1.0]

        def on_line(line):
            # Any advance counts, not only the share of `duration`: an
            # animation without a known duration still reports frames.
            key, _, value = line.partition("=")
            advanced = key in _ADVANCING and seen.get(key) != value
            if advanced:
                seen[key] = value
            progress = parse_ffmpeg_progress(line, duration)
            if progress is not None and (progress >= 1 or progress - last_progress[0] >= 0.01):
                last_progress[0] = progress
                self.sink.emit(stage, progress=progress, **event_fields)
            return advanced

        self._run(args, "FFmpeg could not convert this media.",
                  stall_timeout() if stall is None else stall, on_line)


class _TailBuffer:
    """Keep diagnostic stderr useful without retaining unbounded encoder logs."""

    def __init__(self, limit=8000):
        self.limit = limit
        self.value = ""

    def append(self, chunk):
        self.value = (self.value + chunk)[-self.limit:]


def _drain_tail(stream, tail):
    for chunk in iter(lambda: stream.read(4096), ""):
        tail.append(chunk)
