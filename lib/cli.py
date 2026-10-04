import argparse
import signal
import subprocess
import sys
from pathlib import Path

from . import __version__
from .backend import convert, dependencies
from .errors import Cancelled, OmaConvertError
from .events import EventSink
from . import formats, launcher
from .optimizer import parse_size
from .preview import DEFAULT_EDGE, generate_preview
from .probe import probe_media
from .process import ProcessRunner


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise OmaConvertError("Invalid command line: " + message)


def build_parser():
    parser = JsonArgumentParser(prog="omaconvert", add_help=True)
    parser.add_argument("input", nargs="?", help="input media file")
    parser.add_argument("--format", type=str.lower, choices=formats.cli_choices(),
                        help="output format; jpeg and tif are accepted as jpg and tiff")
    parser.add_argument("--max-size", help="decimal size such as 50MB")
    parser.add_argument("--output", help="destination path")
    parser.add_argument("--output-dir", metavar="DIR",
                        help="destination folder; the default file name is kept")
    parser.add_argument("--preset", choices=("small", "balanced", "high"), default="balanced")
    parser.add_argument("--preference", choices=("motion", "balanced", "detail"), default="balanced")
    parser.add_argument("--probe", metavar="INPUT", help="probe media and exit")
    parser.add_argument("--preview", metavar="INPUT", help="generate a bounded PNG preview and exit")
    parser.add_argument("--preview-output", metavar="PATH", help="destination for --preview PNG")
    parser.add_argument("--preview-size", default=str(DEFAULT_EDGE),
                        help="preview longest edge in pixels (64-640, default 320)")
    parser.add_argument("--preview-position", help="preview seek position in seconds")
    parser.add_argument("--sequence", action="store_true",
                        help="with --format png: write every frame into a <name>-frames folder")
    parser.add_argument("--sequence-fps", help="with --sequence: frames per second to keep (default: all)")
    parser.add_argument("--trim-start", help="convert from this position in seconds")
    parser.add_argument("--trim-end", help="convert up to this position in seconds")
    parser.add_argument("--check", action="store_true", help="check dependencies and exit")
    parser.add_argument("--capabilities", action="store_true",
                        help="report which output formats this FFmpeg can write, as JSON, and exit")
    parser.add_argument("--version", action="store_true", help="print the backend version as JSON and exit")
    parser.add_argument("--open-with", choices=("on", "off", "status"),
                        help="add or remove OmaConvert in file managers' Open With menu and app search")
    return parser


def main(argv=None):
    sink = EventSink()
    runner = ProcessRunner(sink)
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda number, _frame, active=runner: active.cancel(number))
    try:
        args = build_parser().parse_args(argv)
        if args.version:
            sink.emit("version", version=__version__)
            return 0
        if args.open_with:
            try:
                state = (launcher.open_with_status() if args.open_with == "status"
                         else launcher.set_open_with(args.open_with == "on"))
            except (OSError, RuntimeError) as exc:
                raise OmaConvertError("Could not change the Open With entry.", str(exc))
            sink.emit("open-with", **state)
            return 0
        deps = dependencies()
        sink.emit("dependencies", **deps, ok=deps["ffmpeg"] and deps["ffprobe"], version=__version__)
        if args.check:
            return 0 if deps["ffmpeg"] and deps["ffprobe"] else 1
        missing = [name for name in ("ffmpeg", "ffprobe") if not deps[name]]
        if missing:
            raise OmaConvertError("Required media tools are missing.", ", ".join(missing))
        if args.capabilities:
            try:
                tools = formats.toolbox()
            except (OSError, subprocess.SubprocessError) as exc:
                raise OmaConvertError("Could not ask FFmpeg which formats it supports.", str(exc))
            sink.emit("capabilities", **formats.capabilities(tools))
            return 0
        if args.probe:
            path = Path(args.probe).expanduser()
            if not path.is_file():
                raise OmaConvertError("The input file does not exist or is not a regular file.", str(path))
            info = probe_media(path, runner)
            sink.emit("probe", **info.event_fields())
            return 0
        if args.preview:
            if not args.preview_output:
                raise OmaConvertError("--preview-output is required with --preview.")
            try:
                edge = int(args.preview_size)
            except (TypeError, ValueError):
                raise OmaConvertError("Preview size must be a number of pixels, for example 320.")
            position = None
            if args.preview_position is not None:
                try:
                    position = float(args.preview_position)
                except (TypeError, ValueError):
                    raise OmaConvertError("Preview position must be a number of seconds.")
            preview = generate_preview(runner, args.preview, args.preview_output,
                                       max_edge=edge, position=position)
            sink.emit("preview", **preview)
            return 0
        if not args.input:
            raise OmaConvertError("An input file is required.")
        if not args.format:
            raise OmaConvertError(
                "An output format is required: " + ", ".join(f.id for f in formats.FORMATS) + "."
            )
        try:
            requested_bytes = parse_size(args.max_size) if args.max_size else None
        except ValueError as exc:
            raise OmaConvertError(str(exc)) from exc
        trim_start, trim_end = None, None
        for label, raw in (("--trim-start", args.trim_start), ("--trim-end", args.trim_end)):
            if raw is None:
                continue
            try:
                value = float(raw)
            except (TypeError, ValueError):
                raise OmaConvertError(f"{label} must be a number of seconds.")
            if label == "--trim-start":
                trim_start = value
            else:
                trim_end = value
        sequence_fps = None
        if args.sequence_fps is not None:
            if not args.sequence:
                raise OmaConvertError("--sequence-fps needs --sequence.")
            try:
                sequence_fps = float(args.sequence_fps)
            except (TypeError, ValueError):
                raise OmaConvertError("--sequence-fps must be a number of frames per second.")
        complete = convert(runner, args.input, args.format, args.output, requested_bytes,
                           args.preset, args.preference, trim_start, trim_end,
                           output_dir=args.output_dir, sequence=args.sequence,
                           sequence_fps=sequence_fps)
        sink.emit("complete", **complete)
        return 0
    except Cancelled:
        sink.emit("cancelled")
        return 130 if runner.signal_number == signal.SIGINT else 143
    except OmaConvertError as exc:
        sink.emit("error", message=exc.message, details=exc.details)
        return 2
    except Exception as exc:
        sink.emit("error", message="OmaConvert could not complete the conversion.", details=str(exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
