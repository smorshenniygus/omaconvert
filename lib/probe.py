from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path

from .errors import OmaConvertError
from .process import PROBE_TIMEOUT


@dataclass(frozen=True)
class MediaInfo:
    path: str
    duration: float
    width: int
    height: int
    fps: float
    codec: str
    bytes: int
    audio: bool
    stream_index: int = 0
    kind: str = "video"
    transfer: str = ""  # color_transfer, e.g. arib-std-b67 (HLG) or smpte2084 (PQ)

    def event_fields(self):
        return asdict(self)


def _fraction(value):
    try:
        numerator, denominator = value.split("/", 1)
        denominator = float(denominator)
        return float(numerator) / denominator if denominator else 0.0
    except (AttributeError, TypeError, ValueError, ZeroDivisionError):
        return 0.0


def parse_probe_json(raw, path):
    streams = raw.get("streams") or []
    video = next((stream for stream in streams if stream.get("codec_type") == "video" and not (stream.get("disposition") or {}).get("attached_pic")), None)
    if not video:
        raise ValueError("The input does not contain a video stream.")
    fmt = raw.get("format") or {}
    duration = float(fmt.get("duration") or video.get("duration") or 0)
    width = int(video.get("width") or 0)
    height = int(video.get("height") or 0)
    fps = _fraction(video.get("avg_frame_rate")) or _fraction(video.get("r_frame_rate"))
    frame_count = video.get("nb_read_frames") or video.get("nb_frames")
    try:
        frame_count = int(frame_count)
    except (TypeError, ValueError):
        frame_count = None
    format_names = set(str(fmt.get("format_name") or "").split(","))
    image_formats = {"image2", "png_pipe", "jpeg_pipe", "webp_pipe", "bmp_pipe", "tiff_pipe"}
    major_brand = str((fmt.get("tags") or {}).get("major_brand") or "").lower()
    still_evidence = (
        bool(format_names & image_formats)
        or bool((video.get("disposition") or {}).get("still_image"))
        or major_brand in {"avif", "heic", "heix", "hevc", "hevx", "mif1"}
        or ("gif" in format_names and frame_count is not None and frame_count <= 1)
    )
    # A multi-frame count always wins. Conversely, one frame alone is not
    # enough evidence: a legitimate one-frame MP4 remains a video.
    kind = "image" if still_evidence and not (frame_count is not None and frame_count > 1) else "video"
    if kind == "video" and duration <= 0 and frame_count and fps > 0:
        duration = frame_count / fps
    minimum_dimension = 1 if kind == "image" else 2
    unknown_duration_animation = kind == "video" and (
        "webp_anim" in format_names or major_brand in {"avis", "msf1"}
    )
    if (not math.isfinite(duration) or not math.isfinite(fps)
            or width < minimum_dimension or height < minimum_dimension
            or (kind == "video" and (fps <= 0 or (duration <= 0 and not unknown_duration_animation)))):
        raise ValueError("The media metadata is incomplete or invalid.")
    if kind == "image":
        duration = 0.0
        fps = 0.0
    # FFmpeg autorotates from the display matrix. Describe the resulting
    # square-pixel shape, shrinking a dimension rather than upscaling pixels.
    sar = _fraction(str(video.get("sample_aspect_ratio", "1:1")).replace(":", "/")) or 1.0
    if math.isfinite(sar) and sar > 0:
        if sar > 1:
            height = max(2, round(height / sar))
        elif sar < 1:
            width = max(2, round(width * sar))
    rotation = (video.get("tags") or {}).get("rotate", 0)
    for data in video.get("side_data_list") or []:
        if "rotation" in data:
            rotation = data["rotation"]
            break
    try:
        angle = float(rotation) % 360
    except (TypeError, ValueError):
        angle = 0
    if abs(angle - 90) < 1 or abs(angle - 270) < 1:
        width, height = height, width
    try:
        byte_count = int(fmt.get("size") or Path(path).stat().st_size)
    except (OSError, TypeError, ValueError):
        byte_count = 0
    return MediaInfo(
        path=str(Path(path).resolve()),
        duration=duration,
        width=width,
        height=height,
        fps=fps,
        codec=str(video.get("codec_name") or "unknown"),
        bytes=byte_count,
        audio=any(stream.get("codec_type") == "audio" for stream in streams),
        stream_index=int(video.get("index", 0)),
        kind=kind,
        transfer=str(video.get("color_transfer") or ""),
    )


def probe_media(path, runner):
    args = [
        "ffprobe", "-v", "error", "-show_streams", "-show_format",
        "-of", "json", str(path),
    ]
    stdout = runner.capture(args, "Could not read the input media.", timeout=PROBE_TIMEOUT)
    try:
        return parse_probe_json(json.loads(stdout), path)
    except (json.JSONDecodeError, TypeError, ValueError) as exc:
        raise OmaConvertError("Could not read usable media metadata.", str(exc)) from exc
