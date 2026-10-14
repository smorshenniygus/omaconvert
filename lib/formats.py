"""Single registry of OmaConvert formats and what FFmpeg must provide for them.

Everything that lists formats (CLI choices, backend dispatch, the window's
format menu, the file picker filter and the desktop entry MIME types) reads
this module, directly or through the `--capabilities` JSON event.

Availability is measured, not assumed: a present `ffmpeg` binary does not
imply libx264/libvpx/libwebp. `ffmpeg -encoders/-muxers/-filters` is read
once per job or batch, before any worker starts, through the job's
ProcessRunner (so cancelling stops it), and handed on as an immutable
`Toolbox` (see ProcessRunner.toolbox). Input extensions are only a picker
hint; decodability is proven by ffprobe.
"""
from dataclasses import dataclass
import json
import os
import re
import shutil

from .errors import Cancelled, OmaConvertError
from .publish import replace_text


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


def _run(runner, ffmpeg, flag, timeout):
    return runner.capture([ffmpeg, "-hide_banner", flag], "FFmpeg could not list what it supports.",
                          timeout=timeout)


# Asking FFmpeg for its tables costs about 160 ms (three runs); the answer
# changes only when the executable does. Kept for the last few executables.
_DISK_ENTRIES = 8


def _disk_cache_path():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "omaconvert", "toolbox.json")


def _executable_key(ffmpeg):
    real = os.path.realpath(ffmpeg)
    stat = os.stat(real)
    return f"{real}|{stat.st_size}|{stat.st_mtime_ns}|{stat.st_ino}"


def _read_disk_cache():
    try:
        with open(_disk_cache_path(), encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _make_private_folders(folder):
    """Create `folder` and its missing parents, each owner-only. The mode is
    set per folder: the process umask is shared with every other thread and
    must not be changed, even for a moment."""
    missing = []
    while folder and not os.path.isdir(folder):
        missing.append(folder)
        parent = os.path.dirname(folder)
        if parent == folder:
            break
        folder = parent
    for created in reversed(missing):
        try:
            os.mkdir(created, 0o700)
        except FileExistsError:
            continue
        os.chmod(created, 0o700)  # the umask may only have removed bits


def _write_disk_cache(key, tools):
    """Best effort: an unwritable cache only costs the next run 160 ms."""
    path = _disk_cache_path()
    data = _read_disk_cache()
    data.pop(key, None)
    data[key] = {"encoders": sorted(tools.encoders), "muxers": sorted(tools.muxers),
                 "filters": sorted(tools.filters)}
    data = dict(list(data.items())[-_DISK_ENTRIES:])
    try:
        _make_private_folders(os.path.dirname(path))
        replace_text(path, json.dumps(data), 0o600)
    except OSError:
        pass


def _discover(runner, ffmpeg, timeout):
    """Ask FFmpeg, one run after another, so cancelling the job stops the
    one in progress and starts no further one."""
    try:
        return Toolbox(
            frozenset(_table(_run(runner, ffmpeg, "-encoders", timeout))),
            frozenset(_flagged_muxers(_run(runner, ffmpeg, "-muxers", timeout))),
            frozenset(_table(_run(runner, ffmpeg, "-filters", timeout))),
        )
    except Cancelled:
        raise
    except OmaConvertError as exc:
        raise OmaConvertError("Could not ask FFmpeg which formats it supports.",
                              exc.details or exc.message) from exc


def toolbox(runner, ffmpeg=None, timeout=20):
    """What the installed FFmpeg can write, or None without an FFmpeg.

    Read from the disk cache, keyed by the executable's path, size and mtime;
    otherwise FFmpeg is asked through `runner` and the answer is cached.
    Nothing is remembered in this process: a job calls this once before its
    workers start and passes the immutable result on (ProcessRunner.with_toolbox).
    Raises Cancelled when the job is cancelled while FFmpeg is asked, and
    OmaConvertError when it cannot be asked."""
    ffmpeg = ffmpeg or shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    try:
        key = _executable_key(ffmpeg)
    except OSError:
        key = None
    stored = _read_disk_cache().get(key) if key else None
    try:
        tools = Toolbox(frozenset(stored["encoders"]), frozenset(stored["muxers"]),
                        frozenset(stored["filters"])) if stored else None
    except (KeyError, TypeError):
        tools = None
    if tools is None:
        tools = _discover(runner, ffmpeg, timeout)
        if key:
            _write_disk_cache(key, tools)
    return tools


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
