"""Private, bounded records of active scratch paths, surviving a worker OOM."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
from .confinement import runtime_dir

_job = None
_PATTERN = re.compile(r'omaconvert-job-[0-9a-f]{32}\.scope\Z')

def set_job(unit):
    global _job
    if unit is not None and not _PATTERN.fullmatch(unit):
        raise ValueError('Invalid cleanup job identity')
    _job = unit

def job_suffix():
    return (_job + '.') if _job else ''

def _record(path, unit):
    return runtime_dir()/unit/(hashlib.sha256(os.fsencode(os.path.abspath(path))).hexdigest()+'.json')

def register(path):
    if not _job: return
    record = _record(path, _job)
    record.parent.mkdir(mode=0o700,exist_ok=True)
    data = json.dumps({'path':os.path.abspath(path)}).encode()
    if len(data)>4096: raise ValueError('Scratch path exceeds cleanup record budget')
    fd=os.open(record,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream: stream.write(data)

def forget(path):
    if _job: _record(path,_job).unlink(missing_ok=True)

def cleanup_job(unit):
    if not _PATTERN.fullmatch(unit): return
    folder=runtime_dir()/unit
    try:
        st=folder.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077:return
        with os.scandir(folder) as entries:
            for entry in entries:
                if not entry.name.endswith('.json') or not entry.is_file(follow_symlinks=False):continue
                lock=None
                try:
                    fd=os.open(entry.path,os.O_RDONLY|os.O_NOFOLLOW)
                    with os.fdopen(fd,'rb') as stream:data=stream.read(4097)
                    if len(data)>4096:continue
                    target=Path(json.loads(data)['path'])
                    info=target.lstat()
                    if info.st_uid!=os.getuid():continue
                    if stat.S_ISDIR(info.st_mode) and target.name.startswith('.omaconvert-'):
                        lock=os.open(target/'.lock',os.O_RDONLY|os.O_NOFOLLOW)
                        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                        shutil.rmtree(target)
                    elif stat.S_ISREG(info.st_mode) and unit in target.name and target.name.endswith('.tmp.png'):
                        target.unlink()
                except (OSError,ValueError,KeyError,TypeError):
                    pass
                finally:
                    if lock is not None:os.close(lock)
                Path(entry.path).unlink(missing_ok=True)
        try:folder.rmdir()
        except OSError:pass
    except FileNotFoundError:pass
