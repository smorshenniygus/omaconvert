"""Fail-closed Linux resource boundary shared by all media workers.

Only this module talks to the user service manager. A scope is started with
its stdin held at a barrier; no media is opened before verified admission.
"""
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import time
import uuid

from .errors import OmaConvertError

GIB = 1024 ** 3
CGROUP = Path('/sys/fs/cgroup')
SLICE = 'omaconvert.slice'


class ProtectionUnavailable(OmaConvertError):
    reason = 'protection-unavailable'

    def __init__(self, details=''):
        super().__init__('Media protection is unavailable. A working user systemd memory controller is required.', details)


@dataclass(frozen=True)
class Budget:
    total_bytes: int
    inspect_bytes: int


def effective_budget(mem_total: int, ancestor_limits: list[int]) -> Budget:
    capacity = min([mem_total, *ancestor_limits])
    total = min(capacity * 3 // 5, capacity - GIB)
    if total <= 0:
        raise ProtectionUnavailable('Not enough memory to preserve the desktop reserve.')
    return Budget(total, min(2 * GIB, total))


def cgroup_path(pid='self'):
    lines = Path(f'/proc/{pid}/cgroup').read_text().splitlines()
    relative = next(line[3:] for line in lines if line.startswith('0::'))
    return CGROUP / relative.lstrip('/')


def machine_budget():
    try:
        total = next(int(x.split()[1]) * 1024 for x in Path('/proc/meminfo').read_text().splitlines()
                     if x.startswith('MemTotal:'))
        limits = []
        here = cgroup_path()
        # Controller ancestry, not a previous worker's own inspection cap.
        for parent in [here, *here.parents]:
            if parent == CGROUP.parent:
                break
            path = parent / 'memory.max'
            if path.exists():
                raw = path.read_text().strip()
                if raw != 'max':
                    limits.append(int(raw))
        return effective_budget(total, limits)
    except (OSError, ValueError, StopIteration) as exc:
        raise ProtectionUnavailable(str(exc)) from exc


def runtime_dir():
    base = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'))
    root = base / 'omaconvert-workers'
    try:
        root.mkdir(mode=0o700, exist_ok=True)
        st = root.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise ProtectionUnavailable('Worker runtime directory is not private.')
    except OSError as exc:
        raise ProtectionUnavailable(str(exc)) from exc
    return root


def manager(method, signature, *args):
    command = ['busctl', '--user', '--timeout=5', 'call', 'org.freedesktop.systemd1',
               '/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager', method, signature,
               *map(str, args)]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=6)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProtectionUnavailable(str(exc)) from exc
    if result.returncode:
        raise ProtectionUnavailable(result.stderr.decode(errors='replace')[-4096:])
    return result.stdout


def properties(unit):
    try:
        result = subprocess.run(['systemctl', '--user', 'show', unit,
                                 '-p', 'ControlGroup', '-p', 'Result', '-p', 'ActiveState',
                                 '-p', 'MemoryMax', '-p', 'MemorySwapMax'],
                                capture_output=True, text=True, timeout=5)
        if result.returncode:
            raise ProtectionUnavailable(result.stderr[-4096:])
        return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProtectionUnavailable(str(exc)) from exc


def verify_worker(unit: str, memory: int):
    """Actual kernel state, never a flag supplied by the caller."""
    try:
        here = cgroup_path()
        if here.name != unit or here.parent.name != SLICE or not unit.startswith('omaconvert-job-'):
            raise ValueError('Worker is outside its required cgroup.')
        local = int((here / 'memory.max').read_text())
        aggregate = int((here.parent / 'memory.max').read_text())
        if not (0 < local <= memory and 0 < aggregate):
            raise ValueError('Memory limit was not applied.')
        if (here / 'memory.swap.max').read_text().strip() != '0' or (here.parent / 'memory.swap.max').read_text().strip() != '0':
            raise ValueError('Swap limit was not applied.')
        return here
    except (OSError, ValueError, StopIteration) as exc:
        raise ProtectionUnavailable(str(exc)) from exc


class JobScope:
    def __init__(self, memory=None):
        self.budget = machine_budget()
        self.memory = min(memory or self.budget.inspect_bytes, self.budget.total_bytes) // os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PAGE_SIZE")
        self.unit = 'omaconvert-job-' + uuid.uuid4().hex + '.scope'
        self.process = None
        self.path = None
        self.peak = 0
        self.oom_kill = 0
        self._lock = None

    def __enter__(self):
        return self

    def start(self, argv: list[str], profile: str):
        root = runtime_dir()
        fd = os.open(root / 'slice.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        self._lock = fd
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            props = properties(SLICE)
            if props.get('ActiveState') != 'active':
                manager('StartTransientUnit', 'ssa(sv)a(sa(sv))', SLICE, 'fail', 3,
                        'Description', 's', 'OmaConvert active media jobs',
                        'MemoryMax', 't', self.budget.total_bytes,
                        'MemorySwapMax', 't', 0, 0)
            else:
                existing = int(props.get('MemoryMax', '0'))
                if existing <= 0 or existing >= 2**63 or props.get('MemorySwapMax') != '0':
                    raise ProtectionUnavailable('Existing application slice has no valid limit.')
                # Never increase an active application's limit.
                if existing > self.budget.total_bytes:
                    manager('SetUnitProperties', 'sba(sv)', SLICE, 'true', 1,
                            'MemoryMax', 't', self.budget.total_bytes)
            command = ['systemd-run', '--user', '--scope', '--quiet', '--expand-environment=no',
                       '--unit=' + self.unit, '--slice=' + SLICE,
                       '-p', f'MemoryMax={self.memory}', '-p', 'MemorySwapMax=0', '--', *argv]
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, start_new_session=True)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise ProtectionUnavailable(self.process.stderr.read(4096).decode(errors='replace'))
                props = properties(self.unit)
                group = props.get('ControlGroup')
                if group and (CGROUP / group.lstrip('/') / 'memory.max').exists():
                    self.path = CGROUP / group.lstrip('/')
                    self.verify(self.process.pid)
                    return self.process
                time.sleep(.02)
            raise ProtectionUnavailable('Worker cgroup did not start in time.')
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
            self._lock = None

    def verify(self, pid: int):
        try:
            here = cgroup_path(pid)
            if here != self.path or here.parent.name != SLICE:
                raise ValueError('Unexpected worker process ancestry.')
            if int((here / 'memory.max').read_text()) != self.memory:
                raise ValueError('Job memory limit differs.')
            if int((here.parent / 'memory.max').read_text()) > self.budget.total_bytes:
                raise ValueError('Application memory limit exceeds budget.')
            for directory in (here, here.parent):
                if (directory / 'memory.swap.max').read_text().strip() != '0':
                    raise ValueError('Swap was not disabled.')
        except (OSError, ValueError, StopIteration) as exc:
            raise ProtectionUnavailable(str(exc)) from exc

    def observations(self):
        if self.path:
            try:
                self.peak = max(self.peak, int((self.path / 'memory.peak').read_text()))
                counts = dict(line.split() for line in (self.path / 'memory.events').read_text().splitlines())
                self.oom_kill = max(self.oom_kill, int(counts.get('oom_kill', 0)))
            except OSError:
                pass
        props = properties(self.unit)
        return {'memoryPeakSampled': self.peak, 'oomKill': self.oom_kill,
                'result': props.get('Result', ''), 'unit': self.unit, 'memoryMax': self.memory}

    def stop(self):
        if self.process:
            # Stop the entire cgroup, including processes outside the leader's pgid.
            try:
                manager('StopUnit', 'ss', self.unit, 'replace')
            except ProtectionUnavailable:
                pass
            if self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                if stream:
                    stream.close()
            try:
                manager('ResetFailedUnit', 's', self.unit)
            except ProtectionUnavailable:
                pass
        # Stop a transient slice only when it has no populated descendants.
        fd = os.open(runtime_dir() / 'slice.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            props = properties(SLICE)
            group = props.get('ControlGroup')
            if group:
                try:
                    events = dict(line.split() for line in (CGROUP / group.lstrip('/') / 'cgroup.events').read_text().splitlines())
                    if events.get('populated') == '0':
                        manager('StopUnit', 'ss', SLICE, 'replace')
                except OSError:
                    pass
        finally:
            os.close(fd)

    def __exit__(self, *_):
        self.stop()
