"""Bounded preview thumbnails for DEV-04.

Generates a small PNG whose longest edge never exceeds ``max_edge``
(independent of source size) so the QML UI never loads full-size media.
Images are scaled directly; videos seek to a representative frame
(about 25% in, clamped) instead of decoding from the start.
"""
from pathlib import Path

from .color import chain, sdr_filter
from .errors import OmaConvertError
from .probe import probe_media
from .process import PROBE_TIMEOUT

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
    output.parent.mkdir(parents=True, exist_ok=True)

    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
    if seek:
        args += ["-ss", f"{seek:.3f}"]
    args += ["-i", str(source), "-map", f"0:{info.stream_index}",
             "-vf", chain(_scale_filter(max_edge), sdr_filter(info)),
             "-frames:v", "1", "-c:v", "png", str(output)]
    runner.capture(args, "Could not generate a preview image.", timeout=PROBE_TIMEOUT)
    runner.check_cancelled()
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
