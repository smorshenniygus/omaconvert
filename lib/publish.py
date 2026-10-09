from contextlib import contextmanager
import ctypes
import errno
import fcntl
import os
from pathlib import Path
import shutil
import tempfile

WORK_PREFIX = ".omaconvert-"
_LOCK = ".lock"

# link(2) errors meaning "this filesystem has no hard links" (FAT/exFAT,
# many network and FUSE mounts), as opposed to a real failure.
_NO_HARDLINKS = {errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS}


@contextmanager
def work_directory(parent):
    """A hidden working folder in `parent`, on the result's filesystem so
    publishing is a link or a rename. It is locked while in use: a folder
    left by a backend that was killed (no cleanup ran) has a lock nobody
    holds, and the next conversion into the same folder removes it."""
    remove_abandoned(parent)
    directory = tempfile.mkdtemp(prefix=WORK_PREFIX, dir=parent)
    lock = None
    try:
        lock = _hold_lock(directory)
        yield directory
    finally:
        # Removed while still locked, so a sweep never races this cleanup.
        shutil.rmtree(directory, ignore_errors=True)
        if lock is not None:
            os.close(lock)


def _hold_lock(directory):
    """Lock a new file, then give it the name sweeps look for, so `.lock`
    is never seen unlocked while its owner lives. None where the filesystem
    has no flock; such a folder is then never swept."""
    pending = os.path.join(directory, _LOCK + "-new")
    fd = os.open(pending, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.rename(pending, os.path.join(directory, _LOCK))
    except OSError:
        os.close(fd)
        return None
    return fd


def remove_abandoned(parent):
    """Delete our working folders in `parent` whose owner is gone. Folders
    in use, without a lock (older versions) or not ours are left alone."""
    try:
        names = [name for name in os.listdir(parent) if name.startswith(WORK_PREFIX)]
    except OSError:
        return
    for name in names:
        folder = os.path.join(parent, name)
        try:
            info = os.lstat(folder)
            fd = os.open(os.path.join(folder, _LOCK), os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            continue
        try:
            if info.st_uid == os.getuid() and os.path.isdir(folder) and not os.path.islink(folder):
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                shutil.rmtree(folder, ignore_errors=True)
        except OSError:
            pass  # still in use (or no flock here)
        finally:
            os.close(fd)


def _candidate(base, number):
    if number == 1:
        return base
    return base.with_name(f"{base.stem}-{number}{base.suffix}")


def publish_no_clobber(temp_output, requested, forbidden, check_cancelled=None):
    """Publish a same-filesystem file under `requested`, `requested-2`, …
    without replacing any path. Atomic where the filesystem allows it."""
    temp_output = Path(temp_output)
    requested = Path(requested)
    forbidden = Path(forbidden)
    requested.parent.mkdir(parents=False, exist_ok=True)
    forbidden_abs = os.path.abspath(forbidden)
    number = 1
    while True:
        if check_cancelled:
            check_cancelled()
        target = _candidate(requested, number)
        number += 1
        if os.path.abspath(target) == forbidden_abs:
            continue
        try:
            method = _claim(temp_output, target)
        except FileExistsError:
            continue
        try:
            if check_cancelled:
                check_cancelled()
        except BaseException:
            # Retract the new name; the temporary path holds the data again.
            if method == "rename":
                os.rename(target, temp_output)
            else:
                target.unlink(missing_ok=True)
            raise
        if method != "rename":
            temp_output.unlink()
        return target.resolve()


def _claim(temp_output, target):
    """Make `target` a new name for the finished file, failing with
    FileExistsError rather than replacing anything. Returns how: "link"
    (atomic), "rename" (atomic, temp is moved) or "copy" (exclusive create,
    then copy; the partial file is removed on failure)."""
    try:
        os.link(temp_output, target)
        return "link"
    except OSError as exc:
        if exc.errno == errno.EXDEV:
            raise OSError("Temporary output and destination must be on the same filesystem.") from exc
        if exc.errno not in _NO_HARDLINKS:
            raise
    try:
        _rename_noreplace(temp_output, target)
        return "rename"
    except OSError as exc:
        if exc.errno not in (errno.ENOSYS, errno.EINVAL, errno.ENOTSUP, errno.EOPNOTSUPP):
            raise
    _copy_exclusive(temp_output, target)
    return "copy"


def _copy_exclusive(source, target):
    mode = os.stat(source).st_mode & 0o777
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(fd, "wb") as out, open(source, "rb") as src:
            shutil.copyfileobj(src, out, 1024 * 1024)
            out.flush()
            os.fsync(out.fileno())
    except BaseException:
        Path(target).unlink(missing_ok=True)
        raise


_AT_FDCWD = -100
_RENAME_NOREPLACE = 1


def _rename_noreplace(source, target):
    """rename(2) that fails with EEXIST instead of replacing `target`.

    Plain os.rename() silently replaces an empty directory, so a folder is
    published through renameat2(RENAME_NOREPLACE). Raises OSError(ENOSYS or
    EINVAL) where the kernel, libc or filesystem lacks it."""
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise OSError(errno.ENOSYS, "renameat2 is unavailable")
    renameat2.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    if renameat2(_AT_FDCWD, os.fsencode(source), _AT_FDCWD, os.fsencode(target), _RENAME_NOREPLACE) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(target))


def _move_into_new_folder(source, target):
    """Fallback without renameat2: claim `target` with an exclusive mkdir,
    then move the files in. On failure the files go back to `source`."""
    os.mkdir(target)
    moved = []
    try:
        for entry in sorted(os.listdir(source)):
            os.rename(os.path.join(source, entry), os.path.join(target, entry))
            moved.append(entry)
        os.rmdir(source)
    except BaseException:
        for entry in moved:
            os.rename(os.path.join(target, entry), os.path.join(source, entry))
        os.rmdir(target)
        raise


def publish_folder_no_clobber(temp_folder, requested, check_cancelled=None):
    """Publish a same-filesystem folder under `requested`, `requested-2`, …
    without replacing or merging into any existing path."""
    temp_folder = Path(temp_folder)
    requested = Path(requested)
    number = 1
    while True:
        if check_cancelled:
            check_cancelled()
        target = requested if number == 1 else requested.with_name(f"{requested.name}-{number}")
        number += 1
        if os.path.lexists(target):
            continue
        try:
            _rename_noreplace(temp_folder, target)
        except FileExistsError:
            continue
        except OSError as exc:
            if exc.errno == errno.EXDEV:
                raise OSError("Temporary output and destination must be on the same filesystem.") from exc
            if exc.errno not in (errno.ENOSYS, errno.EINVAL):
                raise
            try:
                _move_into_new_folder(temp_folder, target)
            except FileExistsError:
                continue
        try:
            if check_cancelled:
                check_cancelled()
        except BaseException:
            # Retract the visible name; the temporary location is free again.
            os.rename(target, temp_folder)
            raise
        return target.resolve()
