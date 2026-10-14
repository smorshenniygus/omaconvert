"""Small parent: admission, bounded relay and worker lifetime; no decoding."""
import fcntl
import json
import math
import os
from pathlib import Path
import selectors
import signal
import sys
import time

from .confinement import JobScope, ProtectionUnavailable, runtime_dir
from .errors import Cancelled, OmaConvertError
from .streams import OutputLimitExceeded
from .tuning import PROBE_TIMEOUT

EVENT_LIMIT = 65536
TERMINAL = {'complete', 'batch-complete', 'error', 'cancelled'}


def finite_tree(value):
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError('Nonfinite JSON value')
    if isinstance(value, dict):
        for item in value.values(): finite_tree(item)
    elif isinstance(value, list):
        for item in value: finite_tree(item)


def run_controlled(argv, profile, sink):
    cancelled = [None]
    handlers = {}
    for number in (signal.SIGTERM, signal.SIGINT):
        handlers[number] = signal.signal(number, lambda n, _: cancelled.__setitem__(0, n))
    started = time.monotonic()
    admission = None
    scope = None
    terminal = None
    tail = b''
    try:
        if profile in ('convert', 'inspect'):
            admission = os.open(runtime_dir()/(profile + '.lock'), os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW, 0o600)
            announced = False
            while True:
                if cancelled[0]: raise Cancelled('Conversion cancelled.')
                if profile == 'inspect' and time.monotonic() - started >= PROBE_TIMEOUT:
                    raise WorkerFailure('timeout', 'Reading the media took too long and was stopped.')
                try:
                    fcntl.flock(admission, fcntl.LOCK_EX|fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if not announced and profile == 'convert':
                        sink.emit('queued', message='Waiting for another conversion to finish.')
                        announced = True
                    time.sleep(.05)
        from .cleanup import sweep_abandoned
        sweep_abandoned()
        scope = JobScope()
        if profile == 'convert': scope.memory = scope.budget.total_bytes // os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PAGE_SIZE')
        worker = Path(__file__).resolve().parents[1]/'bin'/'omaconvert-worker'
        # Parent-death armed only after systemd-run's exec; the scope path
        # is checked again by the worker, before it imports the media CLI.
        from .process import _through_helper
        args = _through_helper([sys.executable, '-B', str(worker), scope.unit, str(scope.memory), *argv])
        process = scope.start(args, profile)
        process.stdin.write(b'go\n'); process.stdin.flush()
        buffers = {'out': bytearray()}
        observed = {}
        next_sample = 0
        exited_at = None
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, 'out')
            selector.register(process.stderr, selectors.EVENT_READ, 'err')
            while selector.get_map():
                now = time.monotonic()
                if cancelled[0]: raise Cancelled('Conversion cancelled.')
                if scope.guard and scope.guard.poll() is not None:
                    raise ProtectionUnavailable('Lifetime guard stopped unexpectedly.')
                if process.poll() is not None:
                    exited_at = exited_at or now
                    if now - exited_at > 1:
                        raise WorkerFailure('worker-failed', 'The worker exited without closing its streams.')
                if profile == 'inspect' and now - started >= PROBE_TIMEOUT:
                    raise WorkerFailure('timeout', 'Reading the media took too long and was stopped.')
                if now >= next_sample:
                    observed = scope.observations()
                    if observed.get('oomKill') or observed.get('result') == 'oom-kill':
                        raise WorkerFailure('memory-limit', 'The job exceeded its memory budget and was stopped.')
                    next_sample = now + .1
                for key, _ in selector.select(.05):
                    chunk = os.read(key.fileobj.fileno(),4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if key.data == 'err':
                        tail = (tail + chunk)[-8192:]
                        continue
                    buffer = buffers['out']
                    buffer.extend(chunk)
                    while b'\n' in buffer:
                        line, _, rest = buffer.partition(b'\n'); buffer[:] = rest
                        if len(line)+1 > EVENT_LIMIT: raise OutputLimitExceeded()
                        event = json.loads(line)
                        finite_tree(event)
                        if not isinstance(event,dict) or not isinstance(event.get('event'),str):
                            raise ValueError('Invalid worker event')
                        name = event.pop('event')
                        if name in TERMINAL:
                            if terminal is not None: raise ValueError('Multiple terminal events')
                            terminal = (name,event)
                        else:
                            if terminal is not None: raise ValueError('Events after completion')
                            sink.emit(name,**event)
                    if len(buffer) >= EVENT_LIMIT: raise OutputLimitExceeded()
            if buffers['out']: raise ValueError('Incomplete worker event')
        process.wait(timeout=5)
        observed = scope.observations()
        if observed.get('oomKill') or observed.get('result') == 'oom-kill':
            raise WorkerFailure('memory-limit','The job exceeded its memory budget and was stopped.')
        if terminal is not None:
            name, fields = terminal
            if process.returncode and name not in {'error','cancelled'}:
                raise WorkerFailure('worker-failed','The media worker stopped unexpectedly.')
            sink.emit(name, **fields)
        elif process.returncode:
            raise WorkerFailure('worker-failed','The media worker stopped unexpectedly.')
        return process.returncode
    except Cancelled:
        sink.emit('cancelled', reason='cancelled')
        return 130 if cancelled[0] == signal.SIGINT else 143
    except (OmaConvertError, ValueError, OSError, RecursionError) as exc:
        sink.emit('error', reason=getattr(exc,'reason','worker-failed'),
                  message=getattr(exc,'message','The media worker returned an invalid response.'),
                  details=getattr(exc,'details',str(exc))[:4096] or tail.decode(errors='replace')[-4096:])
        return 2
    finally:
        if scope:
            try: scope.stop()
            except ProtectionUnavailable: pass
            from .cleanup import cleanup_job
            cleanup_job(scope.unit)
        if admission is not None: os.close(admission)
        for number, handler in handlers.items(): signal.signal(number,handler)


class WorkerFailure(OmaConvertError):
    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason
