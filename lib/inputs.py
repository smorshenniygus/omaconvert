"""What FFmpeg may open for OmaConvert.

FFmpeg chooses a demuxer by a file's content and extension, and a few of
them do more than read media: AviSynth (.avs) and VapourSynth (.vpy)
scripts run when they are opened, concat, HLS and DASH playlists open the
files and URLs they name, and an SDP file opens network sockets. A file
reaches ffprobe as soon as it is chosen, pasted or opened with OmaConvert,
before anything is converted. So every input, the user's file as well as
the window's own intermediate files, is opened only by the media
containers below and only through the file protocol: a script or a
playlist is refused before anything in it is read or run."""

# Containers of the formats OmaConvert reads (formats.INPUT_EXTENSIONS),
# plus its own intermediates (NUT frames, PNG palettes). image2 is FFmpeg's
# single-image reader for files picked by extension (JPEG).
INPUT_DEMUXERS = (
    "mov", "mp4", "matroska", "webm", "avi", "mpegts", "mpeg", "asf", "flv", "ogg",
    "gif", "apng", "image2", "png_pipe", "jpeg_pipe", "webp_pipe", "bmp_pipe", "tiff_pipe",
    "nut",
)
GUARD = ("-protocol_whitelist", "file", "-format_whitelist", ",".join(INPUT_DEMUXERS))
REFUSED = "Format not on whitelist"


def input_args(path):
    """`-i path` for ffprobe or ffmpeg, behind the demuxer and protocol
    allowlists. Paths are absolute, so a name such as `concat:...` is never
    read as a protocol."""
    return [*GUARD, "-i", str(path)]
