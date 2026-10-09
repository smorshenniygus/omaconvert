"""Single registry of OmaConvert formats and what FFmpeg must provide for them.

Everything that lists formats (CLI choices, backend dispatch, the window's
format menu, the file picker filter and the desktop entry MIME types) reads
this module, directly or through the `--capabilities` JSON event.

Availability is measured, not assumed: a present `ffmpeg` binary does not
imply libx264/libvpx/libwebp. `ffmpeg -encoders/-muxers/-filters` is read
once per process (the window asks once per session and keeps the answer).
Input extensions are only a picker hint; decodability is proven by ffprobe.
"""
from dataclasses import dataclass
import re
import shutil
import subprocess


@dataclass(frozen=True)
class Format:
    id: str                      # canonical CLI value and default extension
    label: str                   # UI label (the window lowercases it for the CLI)
    outputs_for: tuple           # input kinds this format is offered for
    extensions: tuple            # accepted output extensions, canonical first
    alpha: bool                  # transparency can survive
    video_encoders: tuple        # all required
    muxer: str
    audio_encoders: tuple = ()   # required only when the input has sound
    filters: tuple = ()          # all required
    moving: bool = False         # keeps motion for a video input

    @property
    def aliases(self):
        return self.extensions[1:]


# Order is the menu order for a video input; image inputs reuse the same
# order restricted to formats offered for images (GIF first there, see
# `menu_order`).
FORMATS = (
    Format("gif", "GIF", ("video", "image"), ("gif",), True, ("gif",), "gif",
           filters=("palettegen", "paletteuse"), moving=True),
    Format("mp4", "MP4", ("video",), ("mp4",), False, ("libx264",), "mp4",
           audio_encoders=("aac",), moving=True),
    Format("webm", "WebM", ("video",), ("webm",), False, ("libvpx-vp9",), "webm",
           audio_encoders=("libopus",), moving=True),
    Format("mkv", "MKV", ("video",), ("mkv",), False, ("libx264",), "matroska",
           audio_encoders=("aac",), moving=True),
    Format("mov", "MOV", ("video",), ("mov",), False, ("libx264",), "mov",
           audio_encoders=("aac",), moving=True),
    Format("png", "PNG", ("video", "image"), ("png",), True, ("png",), "image2"),
    Format("jpg", "JPG", ("video", "image"), ("jpg", "jpeg"), False, ("mjpeg",), "image2"),
    Format("webp", "WebP", ("video", "image"), ("webp",), True, ("libwebp",), "webp"),
    Format("bmp", "BMP", ("video", "image"), ("bmp",), False, ("bmp",), "image2"),
    Format("tiff", "TIFF", ("video", "image"), ("tiff", "tif"), True, ("tiff",), "image2"),
)
BY_ID = {fmt.id: fmt for fmt in FORMATS}
ALIASES = {ext: fmt.id for fmt in FORMATS for ext in fmt.extensions}
IMAGE_FORMATS = frozenset(fmt.id for fmt in FORMATS if not fmt.moving) | {"gif"}
VIDEO_FORMATS = frozenset(fmt.id for fmt in FORMATS if fmt.moving and fmt.id != "gif")

# Image menu: still formats first, static GIF last (as before the registry).
IMAGE_MENU = ("png", "jpg", "webp", "bmp", "tiff", "gif")

# File picker hint and desktop entry MIME types. FFmpeg decides for real.
INPUT_EXTENSIONS = (
    "mp4", "mov", "mkv", "webm", "avi", "m4v", "mpeg", "mpg", "ts", "mts", "m2ts", "wmv", "flv",
    "ogv", "3gp", "gif", "png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "avif", "heic", "heif",
)
INPUT_MIME_TYPES = (
    "video/mp4", "video/quicktime", "video/x-matroska", "video/webm", "video/x-msvideo",
    "video/x-m4v", "video/mpeg", "video/mp2t", "video/x-ms-wmv", "video/x-flv", "video/ogg",
    "video/3gpp", "image/gif", "image/png", "image/jpeg", "image/webp", "image/bmp",
    "image/tiff", "image/avif", "image/heic", "image/heif",
)


def normalize(value):
    """Canonical format id for a CLI value or extension (`jpeg` -> `jpg`)."""
    return ALIASES.get(str(value or "").lower().lstrip("."))


def cli_choices():
    return tuple(ALIASES)


def menu_order(kind):
    ids = IMAGE_MENU if kind == "image" else tuple(fmt.id for fmt in FORMATS)
    return [BY_ID[i] for i in ids if kind in BY_ID[i].outputs_for]


# ffmpeg table rows: " V....D libx264   description", "  E  mp4   description",
# " DEd alsa   description", " TSC palettegen  V->V  description". Rows are
# recognised by their shape, not by a separator line: FFmpeg before 7.0 ends
# the -muxers legend with "--", later ones with "---", and -filters has no
# separator at all before 8.1. Legend rows ("  T.. = Timeline support") have
# "=" where a row has its name; title rows ("Encoders:") match no flag column.
_ROW = re.compile(r"^\s*([A-Z.|]+d?)\s+(\S+)")


def _rows(text):
    for line in (text or "").splitlines():
        match = _ROW.match(line)
        if match and match.group(2) != "=":
            yield match.group(1), match.group(2)


def _table(text):
    names = set()
    for _flags, name in _rows(text):
        names.update(name.split(","))
    return names


def _flagged_muxers(text):
    """Muxers only: the -muxers/-formats flag column contains E."""
    names = set()
    for flags, name in _rows(text):
        if "E" in flags:
            names.update(name.split(","))
    return names


@dataclass(frozen=True)
class Toolbox:
    encoders: frozenset
    muxers: frozenset
    filters: frozenset


def _run(ffmpeg, flag, timeout):
    completed = subprocess.run([ffmpeg, "-hide_banner", flag], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=timeout)
    if completed.returncode != 0:
        raise OSError((completed.stderr or "").strip() or f"ffmpeg {flag} failed")
    return completed.stdout


_CACHE = {}


def toolbox(ffmpeg=None, timeout=20):
    """What the installed FFmpeg can write. Cached per executable path."""
    ffmpeg = ffmpeg or shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    if ffmpeg not in _CACHE:
        _CACHE[ffmpeg] = Toolbox(
            frozenset(_table(_run(ffmpeg, "-encoders", timeout))),
            frozenset(_flagged_muxers(_run(ffmpeg, "-muxers", timeout))),
            frozenset(_table(_run(ffmpeg, "-filters", timeout))),
        )
    return _CACHE[ffmpeg]


def clear_cache():
    _CACHE.clear()


def missing_for(fmt, tools, audio=False, still=False):
    """FFmpeg components `fmt` needs but `tools` lacks. Audio encoders only
    when the input has sound; filters only for the animated path (a still
    image saved as GIF skips the palette search)."""
    if tools is None:
        return ["ffmpeg"]
    missing = [name for name in fmt.video_encoders if name not in tools.encoders]
    if fmt.muxer not in tools.muxers:
        missing.append(f"{fmt.muxer} muxer")
    if not still:
        missing += [f"{name} filter" for name in fmt.filters if name not in tools.filters]
    if audio:
        missing += [name for name in fmt.audio_encoders if name not in tools.encoders]
    return missing


def unavailable_message(fmt, missing, audio=False):
    what = f"{fmt.label} with sound" if audio else f"{fmt.label} output"
    return (f"{what} needs {', '.join(missing)}, which this FFmpeg build does not provide. "
            "Choose another format or install an FFmpeg build with it.")


def capabilities(tools):
    """JSON-ready description for the `capabilities` event."""
    formats = []
    for fmt in FORMATS:
        missing = missing_for(fmt, tools)
        audio_missing = [name for name in fmt.audio_encoders
                         if tools is None or name not in tools.encoders]
        entry = {
            "id": fmt.id, "label": fmt.label, "outputs_for": list(fmt.outputs_for),
            "extensions": list(fmt.extensions), "alpha": fmt.alpha, "moving": fmt.moving,
            "available": not missing, "missing": missing,
            "reason": unavailable_message(fmt, missing) if missing else "",
        }
        if fmt.audio_encoders:
            entry["audio"] = not audio_missing
            entry["audio_missing"] = audio_missing
        formats.append(entry)
    return {
        "formats": formats,
        "menus": {kind: [fmt.id for fmt in menu_order(kind)] for kind in ("video", "image")},
        "input_extensions": list(INPUT_EXTENSIONS),
    }
