import argparse
import signal
import sys
from pathlib import Path

from . import __version__
from .errors import Cancelled, OmaConvertError
from .events import EventSink
from . import formats
from .preview import DEFAULT_EDGE, forget_preview, generate_preview, media_info_from_meta
from .probe import probe_media
from .process import ProcessRunner, dependencies

# The window starts this CLI for every preview, probe and status: the
# conversion and desktop modules are imported only by the commands that
# use them (about a third of the start-up time of a preview).


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise OmaConvertError("Invalid command line: " + message)


def _number(message, cast=float):
    """argparse type: a number, or our own error message (argparse lets an
    OmaConvertError through untouched, so the JSON error reads as before)."""
    def parse(raw):
        try:
            return cast(raw)
        except (TypeError, ValueError):
            raise OmaConvertError(message) from None
    return parse


def build_parser():
    parser = JsonArgumentParser(prog="omaconvert", add_help=True)
    parser.add_argument("input", nargs="*", help="input media file; several files make a batch with one recipe")
    parser.add_argument("--batch", action="store_true",
                        help="report the inputs as a batch (item and batch-complete events) even when there is one")
    parser.add_argument("--format", type=str.lower, choices=formats.cli_choices(),
                        help="output format; jpeg and tif are accepted as jpg and tiff")
    parser.add_argument("--max-size", help="decimal size such as 50MB")
    parser.add_argument("--output", help="destination path")
    parser.add_argument("--output-dir", metavar="DIR",
                        help="destination folder; the default file name is kept")
    parser.add_argument("--preset", choices=("small", "balanced", "high"), default="balanced")
    parser.add_argument("--preference", choices=("motion", "balanced", "detail"), default="balanced")
    parser.add_argument("--probe", metavar="INPUT", help="probe media and exit")
    parser.add_argument("--probe-all", action="store_true",
                        help="probe every input (a probe-item event each) and exit")
    parser.add_argument("--preview", metavar="INPUT", help="generate a bounded PNG preview and exit")
    parser.add_argument("--preview-output", metavar="PATH", help="destination for --preview PNG")
    parser.add_argument("--preview-size", default=DEFAULT_EDGE,
                        type=_number("Preview size must be a number of pixels, for example 320.", int),
                        help="preview longest edge in pixels (64-640, default 320)")
    parser.add_argument("--preview-position", type=_number("Preview position must be a number of seconds."),
                        help="preview seek position in seconds")
    parser.add_argument("--preview-meta", metavar="JSON",
                        help="the probe event of the --preview input, to skip probing it again")
    parser.add_argument("--preview-fast", action="store_true",
                        help="take the keyframe at or before --preview-position (for scrubbing)")
    parser.add_argument("--forget-preview", metavar="PATH", action="append",
                        help="delete a cached window preview (src-preview.png or res-preview.png) and exit")
    parser.add_argument("--sequence", action="store_true",
                        help="with --format png: write every frame into a <name>-frames folder")
    parser.add_argument("--sequence-fps", type=_number("--sequence-fps must be a number of frames per second."),
                        help="with --sequence: frames per second to keep (default: all)")
    parser.add_argument("--trim-start", type=_number("--trim-start must be a number of seconds."),
                        help="convert from this position in seconds")
    parser.add_argument("--trim-end", type=_number("--trim-end must be a number of seconds."),
                        help="convert up to this position in seconds")
    parser.add_argument("--check", action="store_true", help="check dependencies and exit")
    parser.add_argument("--capabilities", action="store_true",
                        help="report which output formats this FFmpeg can write, as JSON, and exit")
    parser.add_argument("--version", action="store_true", help="print the backend version as JSON and exit")
    parser.add_argument("--status", action="store_true",
                        help="everything the window needs when it opens, as one status event, and exit")
    parser.add_argument("--paste", action="store_true",
                        help="report what the clipboard holds for the window (an image is saved to Pictures/OmaConvert)")
    parser.add_argument("--hotkey", choices=("on", "off", "status"),
                        help="add or remove the OmaConvert key binding in ~/.config/hypr/bindings.lua")
    parser.add_argument("--offer-recording", metavar="PATH",
                        help="notify that a finished screen recording can be shrunk in OmaConvert")
    parser.add_argument("--open-with", choices=("on", "off", "status"),
                        help="add or remove OmaConvert in file managers' Open With menu and app search")
    return parser


def _status(runner):
    """Version, dependencies, format capabilities, the Open With entry and
    the hotkey in one event: one process when the window opens instead of
    four. A part that cannot be read is reported with an `error` field."""
    from . import desktop, launcher
    deps = dependencies()
    missing = [name for name in ("ffmpeg", "ffprobe") if not deps[name]]
    status = {"version": __version__, "dependencies": dict(deps, ok=not missing)}
    if missing:
        status["error"] = {
            "message": "Required media tools are missing: " + ", ".join(missing) + ". Install FFmpeg.",
            "details": "Not found on PATH: " + ", ".join(missing)}
    else:
        try:
            status["capabilities"] = formats.capabilities(formats.toolbox(runner))
        except Cancelled:
            raise
        except OmaConvertError as exc:
            status["capabilities_error"] = exc.details or exc.message
    for name, read in (("open_with", launcher.open_with_status), ("hotkey", desktop.hotkey_status)):
        try:
            status[name] = read()
        except (OSError, RuntimeError) as exc:
            status[name] = {"error": str(exc)}
    return status


def operation_for(args):
    return next((name for name in ("version", "status", "paste", "hotkey", "offer_recording",
        "open_with", "check", "capabilities", "probe_all", "probe", "forget_preview", "preview")
        if getattr(args, name)), "convert")


def run_worker(argv=None):
    sink = EventSink()
    runner = ProcessRunner(sink)
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda number, _frame, active=runner: active.cancel(number))
    try:
        args = build_parser().parse_args(argv)
        operation = operation_for(args)
        if operation == "version":
            sink.emit("version", version=__version__)
            return 0
        if operation == "status":
            sink.emit("status", **_status(runner))
            return 0
        if operation == "paste":
            from . import desktop
            sink.emit("paste", **desktop.paste())
            return 0
        if operation == "hotkey":
            from . import desktop
            try:
                state = desktop.hotkey_status() if args.hotkey == "status" else desktop.set_hotkey(args.hotkey == "on")
            except (OSError, RuntimeError) as exc:
                raise OmaConvertError("Could not change the hotkey.", str(exc))
            sink.emit("hotkey", **state)
            return 0
        if operation == "offer_recording":
            from . import desktop
            sink.emit("recording-offer", **desktop.offer_recording(args.offer_recording))
            return 0
        if operation == "open_with":
            from . import launcher
            try:
                state = (launcher.open_with_status() if args.open_with == "status"
                         else launcher.set_open_with(args.open_with == "on"))
            except (OSError, RuntimeError) as exc:
                raise OmaConvertError("Could not change the Open With entry.", str(exc))
            sink.emit("open-with", **state)
            return 0
        deps = dependencies()
        sink.emit("dependencies", **deps, ok=deps["ffmpeg"] and deps["ffprobe"], version=__version__)
        missing = [name for name in ("ffmpeg", "ffprobe") if not deps[name]]
        if missing:
            # --check too: the window shows this error rather than a bare exit code.
            raise OmaConvertError("Required media tools are missing: " + ", ".join(missing) + ". Install FFmpeg.",
                                  "Not found on PATH: " + ", ".join(missing))
        if operation == "check":
            return 0
        if operation == "capabilities":
            sink.emit("capabilities", **formats.capabilities(formats.toolbox(runner)))
            return 0
        if operation == "probe_all":
            from .backend import probe_all
            probe_all(runner, args.input)
            return 0
        if operation == "probe":
            path = Path(args.probe).expanduser().absolute()
            if not path.is_file():
                raise OmaConvertError("The input file does not exist or is not a regular file.", str(path))
            info = probe_media(path, runner)
            sink.emit("probe", **info.event_fields())
            return 0
        if operation == "forget_preview":
            for path in args.forget_preview:
                sink.emit("forgotten", **forget_preview(path))
            return 0
        if operation == "preview":
            if not args.preview_output:
                raise OmaConvertError("--preview-output is required with --preview.")
            info = media_info_from_meta(args.preview_meta) if args.preview_meta else None
            preview = generate_preview(runner, args.preview, args.preview_output,
                                       max_edge=args.preview_size, position=args.preview_position,
                                       info=info, fast=args.preview_fast)
            sink.emit("preview", **preview)
            return 0
        # The window sends --batch: what is left of a selection may be one file.
        batch = args.batch or len(args.input) > 1
        if batch and args.output:
            raise OmaConvertError("A batch needs --output-dir, not --output.")
        if not args.input:
            raise OmaConvertError("An input file is required.")
        if not args.format:
            raise OmaConvertError(
                "An output format is required: " + ", ".join(f.id for f in formats.FORMATS) + "."
            )
        from .backend import convert, convert_batch
        from .optimizer import parse_size
        try:
            requested_bytes = parse_size(args.max_size) if args.max_size else None
        except ValueError as exc:
            raise OmaConvertError(str(exc)) from exc
        trim_start, trim_end, sequence_fps = args.trim_start, args.trim_end, args.sequence_fps
        if sequence_fps is not None and not args.sequence:
            raise OmaConvertError("--sequence-fps needs --sequence.")
        if batch:
            if trim_start is not None or trim_end is not None:
                raise OmaConvertError("Trimming applies to one video at a time.")
            summary = convert_batch(runner, args.input, args.format, requested_bytes, args.preset,
                                    args.preference, output_dir=args.output_dir, sequence=args.sequence,
                                    sequence_fps=sequence_fps)
            sink.emit("batch-complete", **summary)
            return 0
        complete = convert(runner, args.input[0], args.format, args.output, requested_bytes,
                           args.preset, args.preference, trim_start, trim_end,
                           output_dir=args.output_dir, sequence=args.sequence,
                           sequence_fps=sequence_fps)
        sink.emit("complete", **complete)
        return 0
    except Cancelled:
        sink.emit("cancelled")
        return 130 if runner.signal_number == signal.SIGINT else 143
    except OmaConvertError as exc:
        sink.emit("error", message=exc.message, details=exc.details[:4096], reason=getattr(exc, "reason", "worker-failed"))
        return 2
    except Exception as exc:
        sink.emit("error", message="OmaConvert could not complete the conversion.", details=str(exc))
        return 2


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        args = build_parser().parse_args(argv)
    except OmaConvertError as exc:
        EventSink().emit("error", message=exc.message, details=exc.details)
        return 2
    # Match run_worker's precedence exactly: combined flags cannot use a
    # lower-priority utility to bypass an earlier media operation.
    operation = operation_for(args)
    if operation in {"version", "paste", "hotkey", "offer_recording", "open_with", "check", "forget_preview"}:
        return run_worker(argv)
    from .controller import run_controlled
    return run_controlled(argv, "convert" if operation == "convert" else "inspect", EventSink())


if __name__ == "__main__":
    sys.exit(main())
