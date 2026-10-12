"""Bounded preview thumbnails for DEV-04.

Generates a small PNG whose longest edge never exceeds ``max_edge``
(independent of source size) so the QML UI never loads full-size media.
Images are scaled directly; videos seek to a representative frame
(about 25% in, clamped) instead of decoding from the start.
"""
from contextlib import contextmanager
import json
import os
import stat
from pathlib import Path
import tempfile

from .color import chain, sdr_filter
from .errors import OmaConvertError
from .probe import MediaInfo, probe_media
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


def _scale_filter(max_edge, info):
    # Probe dimensions already account for pixel aspect and autorotation.
    # Fit that display shape, not the encoded pixel grid, before resetting SAR.
    ratio = max_edge / max(info.width, info.height)
    width = max(1, round(info.width * ratio))
    height = max(1, round(info.height * ratio))
    return f"scale={width}:{height}:flags=lanczos,setsar=1"


_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_size(path):
    """(width, height) from the IHDR chunk, which a PNG must start with.
    Reading 24 bytes replaces an ffprobe run on every preview."""
    with open(path, "rb") as handle:
        head = handle.read(24)
    if len(head) < 24 or head[:8] != _PNG_SIGNATURE or head[12:16] != b"IHDR":
        raise OmaConvertError("Could not generate a preview image.", "The output is not a PNG.")
    width, height = int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")
    if width <= 0 or height <= 0:
        raise OmaConvertError("Could not generate a preview image.", "The PNG has no pixels.")
    return width, height


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
    """Create `folder` owner-only. A folder that is a link or belongs to
    someone else is refused: the window loads the thumbnail written there.
    The window's own cache folders are also tightened when an older version
    left them 0755."""
    with _private_umask():
        folder.mkdir(parents=True, exist_ok=True)
    try:
        info = os.lstat(folder)
    except OSError as exc:
        raise OmaConvertError("Could not create the preview folder.", str(exc)) from exc
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OmaConvertError("The preview folder is not a private folder of yours.", str(folder))
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


def media_info_from_meta(raw):
    """The window's probe event (JSON) as MediaInfo, so a preview of a file
    the window already read skips ffprobe (about 40-60 ms)."""
    from dataclasses import fields
    try:
        data = json.loads(raw)
        known = {f.name for f in fields(MediaInfo)}
        return MediaInfo(**{key: value for key, value in data.items() if key in known})
    except (TypeError, ValueError) as exc:
        raise OmaConvertError("--preview-meta must be the probe event of this file as JSON.", str(exc)) from exc


def generate_preview(runner, input_path, output_path, max_edge=DEFAULT_EDGE,
                     position=None, info=None, fast=False):
    """Extract one bounded PNG preview. Returns dict with path/width/height/bytes.

    `info` is the probe of this file when the caller already has it. `fast`
    takes the keyframe at or before `position` instead of decoding up to the
    exact frame: for scrubbing, where the exact frame follows on release."""
    max_edge = clamp_edge(max_edge)
    source = Path(input_path).expanduser().absolute()
    if not source.is_file():
        raise OmaConvertError(
            "The input file does not exist or is not a regular file.", str(source))
    if info is None:
        info = probe_media(source, runner)
    seek = preview_position(info, position)
    fast = bool(fast and seek and info.kind != "image")
    output = Path(output_path).expanduser()
    _private_folder(output.parent)

    # The thumbnail shows the file's content, so it is owner-only (0600)
    # whatever the source's mode: FFmpeg writes into a file created 0600,
    # which then replaces the old preview in one step.
    fd, temp_name = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".tmp.png", dir=output.parent)
    os.close(fd)
    temp = Path(temp_name)

    def extract(keyframe_only):
        args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        if keyframe_only:
            args += ["-skip_frame", "nokey", "-noaccurate_seek"]
        if seek:
            args += ["-ss", f"{seek:.3f}"]
        args += ["-i", str(source), "-map", f"0:{info.stream_index}",
                 "-vf", chain(_scale_filter(max_edge, info), sdr_filter(info)),
                 "-frames:v", "1", "-c:v", "png", "-f", "image2", "-update", "1", str(temp)]
        with _private_umask():
            runner.capture(args, "Could not generate a preview image.", timeout=PROBE_TIMEOUT)
        runner.check_cancelled()

    try:
        if fast:
            # Some files give no keyframe this way (FFmpeg drops it before
            # the seek point); then the draft is simply the exact frame.
            extract(True)
            if temp.stat().st_size == 0:
                fast = False
        if not fast:
            extract(False)
        temp.chmod(0o600)
        os.replace(temp, output)
    finally:
        temp.unlink(missing_ok=True)
    try:
        size = output.stat().st_size
        width, height = png_size(output)
    except OSError as exc:
        raise OmaConvertError("Could not generate a preview image.", str(exc)) from exc
    return {
        "path": str(output.resolve()),
        "width": width,
        "height": height,
        "bytes": size,
        "kind": info.kind,
        "source": str(source.resolve()),
        "seek": seek or 0.0,
        "draft": fast,
    }
