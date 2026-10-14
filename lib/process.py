import functools
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time

from .errors import Cancelled, ProcessFailed
from .tuning import (DEFAULT_STALL_TIMEOUT, ENCODE_MEMORY_MIN, ENCODE_MEMORY_SHARE,  # noqa: F401
                     INSPECT_MEMORY, PROBE_TIMEOUT)


@functools.cache
def encode_memory():
    """Memory cap of an encoder: a share of the machine's RAM."""
    try:
        with open("/proc/meminfo") as handle:
            total = next(int(line.split()[1]) * 1024 for line in handle if line.startswith("MemTotal:"))
    except (OSError, StopIteration, ValueError):
        return ENCODE_MEMORY_MIN * 4
    return max(ENCODE_MEMORY_MIN, int(total * ENCODE_MEMORY_SHARE))


@functools.cache
def _scope_available():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    return bool(shutil.which("systemd-run", path=os.defpath) and runtime and os.path.exists(os.path.join(runtime, "systemd", "private")))


@functools.cache
def _scope_options():
    """systemd 254+ expands $VARIABLES in the command it runs; file names
    must reach the tool exactly as they are."""
    try:
        first = subprocess.run([shutil.which("systemd-run", path=os.defpath) or "systemd-run", "--version"], capture_output=True, text=True, timeout=5).stdout.split()
        version = int(first[1]) if len(first) > 1 and first[1].isdigit() else 0
    except (OSError, subprocess.SubprocessError, ValueError):
        version = 0
    return ["--expand-environment=no"] if version >= 254 else []


def confined(args, memory):
    """`args` with a memory cap of `memory` bytes. A user systemd scope caps
    the memory actually used (swap off) and is the same process, so process
    groups and the parent-death signal still apply. Without a user manager,
    prlimit caps the address space instead: looser, since threads reserve
    address space they never use, hence the larger figure."""
    from .confinement import cgroup_path, verify_worker
    here = cgroup_path()
    if here.name.startswith("omaconvert-job-") and here.parent.name == "omaconvert.slice":
        verify_worker(here.name, int((here / "memory.max").read_text()))
        return list(args)
    if _scope_available():
        return [shutil.which("systemd-run", path=os.defpath) or "systemd-run", "--user", "--scope", "--quiet", "--collect", *_scope_options(),
                "-p", f"MemoryMax={memory}", "-p", "MemorySwapMax=0", "--", *args]
    from .confinement import ProtectionUnavailable
    raise ProtectionUnavailable("No user systemd manager is available.")


# Media tools start through bin/omaconvert-exec, which makes Linux SIGKILL
# them when the backend dies and then execs the tool.
#
# The window kills the backend outright when the shell reloads. Tools run in
# their own session (for killpg) and FFmpeg ignores SIGPIPE, so they would
# otherwise keep encoding for minutes into a folder nobody cleans.
#
# Linux ties the signal to the thread that started the helper, not to the
# process: that thread must stay alive until the tool exits. Every launch
# goes through _run, where the starting thread (the main thread, or a batch
# worker) also waits for the tool, so the rule holds. Do not start a tool
# from a short-lived thread and wait for it elsewhere.
_HELPER = Path(__file__).resolve().parents[1] / "bin" / "omaconvert-exec"
_HELPER_NOT_STARTED = 127  # the helper's exit status when it could not exec the tool


def _through_helper(args):
    """`args` wrapped to run so that the tool dies with this process.

    -I -S -B: start fast and import nothing from the user's site or the
    current directory; the helper is standalone."""
    if not sys.platform.startswith("linux"):
        return list(args)
    return [sys.executable, "-I", "-S", "-B", str(_HELPER), str(os.getpid()), *args]


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


class _Supervision:
    """What every runner of one backend shares: the running tools, so
    cancelling stops all of them, whether the job was cancelled, and FFmpeg's
    capabilities once the job has asked for them."""

    def __init__(self):
        self.lock = threading.RLock()
        self.active = set()
        self.cancelled = False
        self.signal_number = None
        self.terminators = {}
        self.timed_out = set()
        self.toolbox = None
        self.toolbox_lock = threading.Lock()  # not `lock`: cancelling must not wait for a question


class ProcessRunner:
    def __init__(self, sink, supervision=None):
        self.sink = sink
        self._shared = supervision or _Supervision()
        self._lock = self._shared.lock
        self._terminators = self._shared.terminators
        self._timed_out = self._shared.timed_out

    @property
    def cancelled(self):
        return self._shared.cancelled

    @property
    def signal_number(self):
        return self._shared.signal_number

    def for_sink(self, sink):
        """A runner reporting to `sink` that is cancelled with this one:
        one per file of a batch converted in parallel."""
        return ProcessRunner(sink, self._shared)

    @property
    def toolbox(self):
        """What the installed FFmpeg can do (formats.Toolbox): None until
        `prepare_toolbox` has run, and without an FFmpeg."""
        return self._shared.toolbox

    def prepare_toolbox(self):
        """Ask FFmpeg what it can do, once for the job: every runner made
        from this one sees the answer. A job calls this before it starts
        workers, which then only read the immutable Toolbox. Asking runs
        through this runner, so cancelling the job stops it."""
        with self._shared.toolbox_lock:
            if self._shared.toolbox is None:
                from . import formats
                self._shared.toolbox = formats.toolbox(self)
            return self._shared.toolbox

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
            self._shared.cancelled = True
            self._shared.signal_number = signal_number
            processes = list(self._shared.active)
        for process in processes:
            self._terminate(process)

    def _start(self, args, memory):
        self.check_cancelled()
        try:
            process = subprocess.Popen(
                confined(_through_helper(args), memory),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except OSError as exc:
            raise ProcessFailed("Could not start a required media tool.", str(exc)) from exc
        with self._lock:
            self._shared.active.add(process)
            cancelled = self.cancelled
        if cancelled:
            self._terminate(process)
        return process

    def _watch(self, process, limit, last_activity, drained):
        """Stop `process` once `last_activity()` is older than `limit` seconds."""
        if not limit:
            return None

        def watchdog():
            while not drained.is_set():
                if time.monotonic() - last_activity() > limit:
                    with self._lock:
                        self._timed_out.add(process)
                    self._terminate(process)
                    return
                time.sleep(0.1)

        thread = threading.Thread(target=watchdog, daemon=True)
        thread.start()
        return thread

    def _finish(self, process, stderr, message, memory):
        with self._lock:
            self._shared.active.discard(process)
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
            if process.returncode == _HELPER_NOT_STARTED and "omaconvert-exec: cannot start" in details:
                raise ProcessFailed("Could not start a required media tool.", details)
            lowered = details.lower()
            if "no space left on device" in lowered:
                message = "Conversion failed because the destination disk is full."
            elif "permission denied" in lowered:
                message = "Conversion failed because the destination is not writable."
            raise ProcessFailed(message, details)

    def _run(self, args, message, limit, on_line=None, memory=None):
        """Start `args`, keep a bounded stderr tail, stop the tool once nothing
        happened for `limit` seconds, and turn failures into errors.

        Without `on_line` stdout is collected and returned, and `limit`
        bounds the total wall time. With it every stdout line is passed on;
        a line for which it returns True counts as activity."""
        memory = memory or encode_memory()
        process = self._start(args, memory)
        stderr_tail = _TailBuffer()
        thread = threading.Thread(target=_drain_tail, args=(process.stderr, stderr_tail), daemon=True)
        thread.start()
        activity = [time.monotonic()]
        drained = threading.Event()
        self._watch(process, limit, lambda: activity[0], drained)
        from .streams import read_bounded, iter_bounded_lines, OutputLimitExceeded
        stdout = None
        try:
            if on_line is None:
                stdout = read_bounded(process.stdout, 1024 * 1024).decode("utf-8", errors="replace")
            else:
                for raw in iter_bounded_lines(process.stdout, 16384):
                    if on_line(raw.decode("utf-8", errors="replace").strip()):
                        activity[0] = time.monotonic()
        except OutputLimitExceeded:
            self._terminate(process)
            process.wait()
            thread.join(timeout=2)
            process.stdout.close()
            process.stderr.close()
            with self._lock:
                self._shared.active.discard(process)
                self._timed_out.discard(process)
                terminator = self._terminators.pop(process, None)
            if terminator: terminator.join(timeout=2)
            drained.set()
            raise
        process.wait()
        thread.join()
        drained.set()
        process.stdout.close()
        process.stderr.close()
        self._finish(process, stderr_tail.value, message, memory)
        return stdout

    def capture(self, args, message, timeout=None, memory=None):
        """Run a tool to completion; `timeout` bounds its total wall time and
        `memory` its RAM (bytes; an encoder's share of the machine by default)."""
        return self._run(args, message, timeout, memory=memory)

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
        self._value = b""

    def append(self, chunk):
        self._value = (self._value + chunk.encode("utf-8"))[-self.limit:]

    @property
    def value(self):
        return self._value.decode("utf-8", errors="replace")


def _drain_tail(stream, tail):
    for chunk in iter(lambda: stream.read(4096), b""):
        tail.append(chunk.decode("utf-8", errors="replace"))
