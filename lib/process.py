import os
import signal
import subprocess
import threading
import time

from .errors import Cancelled, ProcessFailed

# Probing and previews are bounded single reads: minutes of silence mean the
# tool hung (network mount, broken decoder), not a slow but healthy job.
PROBE_TIMEOUT = 120.0
# FFmpeg encodes report progress continuously; if the reported position does
# not advance for this long, the encoder is considered stuck. Override with
# OMACONVERT_STALL_TIMEOUT (seconds, 0 disables) for unusual hardware.
DEFAULT_STALL_TIMEOUT = 300.0


def stall_timeout():
    raw = os.environ.get("OMACONVERT_STALL_TIMEOUT", "")
    try:
        value = float(raw) if raw else DEFAULT_STALL_TIMEOUT
    except ValueError:
        return DEFAULT_STALL_TIMEOUT
    return value if value > 0 else None


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

        def force_after_grace():
            deadline = time.monotonic() + 3
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

    def capture(self, args, message, timeout=None):
        """Run a tool to completion; `timeout` bounds its total wall time."""
        process = self._start(args)
        stderr_tail = _TailBuffer()
        thread = threading.Thread(target=_drain_tail, args=(process.stderr, stderr_tail), daemon=True)
        thread.start()
        started = time.monotonic()
        self._watch(process, timeout, lambda: started)
        stdout = process.stdout.read()
        process.wait()
        thread.join()
        process.stdout.close()
        process.stderr.close()
        self._finish(process, stderr_tail.value, message)
        return stdout

    def ffmpeg(self, args, duration, stage="encoding", stall=None, **event_fields):
        """Run an FFmpeg encode with -progress; stop it if progress stalls."""
        from .encoders import parse_ffmpeg_progress
        process = self._start(args)
        stderr_tail = _TailBuffer()
        thread = threading.Thread(target=_drain_tail, args=(process.stderr, stderr_tail), daemon=True)
        thread.start()
        activity = [time.monotonic()]
        seen = [None]
        self._watch(process, stall_timeout() if stall is None else stall, lambda: activity[0])
        last_progress = -1.0
        for line in process.stdout:
            progress = parse_ffmpeg_progress(line.strip(), duration)
            if progress is not None and progress != seen[0]:
                seen[0] = progress
                activity[0] = time.monotonic()
            if progress is not None and (progress >= 1 or progress - last_progress >= 0.01):
                last_progress = progress
                self.sink.emit(stage, progress=progress, **event_fields)
        process.wait()
        thread.join()
        process.stdout.close()
        process.stderr.close()
        self._finish(process, stderr_tail.value, "FFmpeg could not convert this media.")


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
