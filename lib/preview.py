"""Bounded preview thumbnails for DEV-04.

Generates a small PNG whose longest edge never exceeds ``max_edge``
(independent of source size) so the QML UI never loads full-size media.
Images are scaled directly; videos seek to a representative frame
(about 25% in, clamped) instead of decoding from the start.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import tempfile

from .color import chain, sdr_filter
from .errors import OmaConvertError
from .probe import probe_media
from .process import PROBE_TIMEOUT

# The window's two cache files. --forget-preview deletes only these names.
PREVIEW_NAMES = ("src-preview.png", "res-preview.png")
DEFAULT_EDGE = 320
MIN_EDGE = 64
MAX_EDGE = 640


def clamp_edge(value):
    try:
        edge = int(value)
    except (TypeError, ValueError):
        return DEFAULT_EDGE
    return max(MIN_EDGE, min(MAX_EDGE, edge))


def preview_position(info, requested=None):
    """Choose a seek position in seconds, or None for the first frame."""
    if requested is not None:
        try:
            position = float(requested)
        except (TypeError, ValueError):
            raise OmaConvertError("Preview position must be a number of seconds.")
        if position < 0:
            raise OmaConvertError("Preview position must be zero or later.")
        if info.kind != "image" and info.duration > 0:
            position = min(position, max(0.0, info.duration - 0.1))
        return max(0.0, position)
    if info.kind == "image" or info.duration <= 0:
        return None
    if info.duration <= 0.6:
        return 0.0
    # ~25% in: avoids black leader frames at 0 and credits at the very end.
    position = info.duration * 0.25
    position = max(0.3, min(position, info.duration - 0.1, 10.0))
    return round(position, 3)


def _scale_filter(max_edge):
    return (
        f"scale={max_edge}:{max_edge}:"
        "force_original_aspect_ratio=decrease:flags=lanczos,setsar=1"
    )


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(base) / "omaconvert" / "previews"


@contextmanager
def _private_umask():
    """Files and folders created inside (FFmpeg's too) are owner-only."""
    old = os.umask(0o077)
    try:
        yield
    finally:
        os.umask(old)


def _private_folder(folder):
    """Create `folder` owner-only. The window's own cache folders are also
    tightened when an older version left them 0755."""
    with _private_umask():
        folder.mkdir(parents=True, exist_ok=True)
    own = cache_dir()
    if os.path.abspath(folder) == os.path.abspath(own):
        for path in (own, own.parent):
            try:
                if path.stat().st_uid == os.getuid():
                    path.chmod(0o700)
            except OSError:
                pass


def forget_preview(path):
    """Delete one of the window's cached thumbnails (and any half-written
    temporary next to it). Other names are refused, so this never becomes
    a general way to delete files."""
    target = Path(path).expanduser()
    if target.name not in PREVIEW_NAMES:
        raise OmaConvertError("Only OmaConvert preview files can be forgotten.", str(target))
    removed = False
    if target.is_symlink() or target.is_file():
        target.unlink()
        removed = True
    if target.parent.is_dir():
        for stale in target.parent.glob(f".{target.name}.*.tmp.png"):
            stale.unlink(missing_ok=True)
    return {"path": str(target), "removed": removed}


def generate_preview(runner, input_path, output_path, max_edge=DEFAULT_EDGE,
                     position=None):
    """Extract one bounded PNG preview. Returns dict with path/width/height/bytes."""
    max_edge = clamp_edge(max_edge)
    source = Path(input_path).expanduser()
    if not source.is_file():
        raise OmaConvertError(
            "The input file does not exist or is not a regular file.", str(source))
    info = probe_media(source, runner)
    seek = preview_position(info, position)
    output = Path(output_path).expanduser()
    _private_folder(output.parent)

    # The thumbnail shows the file's content, so it is owner-only (0600)
    # whatever the source's mode: FFmpeg writes into a file created 0600,
    # which then replaces the old preview in one step.
    fd, temp_name = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".tmp.png", dir=output.parent)
    os.close(fd)
    temp = Path(temp_name)
    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
    if seek:
        args += ["-ss", f"{seek:.3f}"]
    args += ["-i", str(source), "-map", f"0:{info.stream_index}",
             "-vf", chain(_scale_filter(max_edge), sdr_filter(info)),
             "-frames:v", "1", "-c:v", "png", "-f", "image2", "-update", "1", str(temp)]
    try:
        with _private_umask():
            runner.capture(args, "Could not generate a preview image.", timeout=PROBE_TIMEOUT)
        runner.check_cancelled()
        temp.chmod(0o600)
        os.replace(temp, output)
    finally:
        temp.unlink(missing_ok=True)
    try:
        size = output.stat().st_size
        if size <= 0:
            raise OmaConvertError("Could not generate a preview image.", "Empty output.")
        preview_info = probe_media(output, runner)
    except OSError as exc:
        raise OmaConvertError("Could not generate a preview image.", str(exc)) from exc
    return {
        "path": str(output.resolve()),
        "width": preview_info.width,
        "height": preview_info.height,
        "bytes": size,
        "kind": info.kind,
        "source": str(source.resolve()),
        "seek": seek or 0.0,
    }
