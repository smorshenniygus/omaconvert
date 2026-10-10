import math
import os
from dataclasses import replace
from pathlib import Path
import shutil
import subprocess

from .color import sdr_filter
from .encoders import (
    TARGET_AUDIO_RATE, encode_gif, encode_image_quick, encode_image_target, encode_png_sequence,
    encode_video_quick, encode_video_target,
)
from .errors import Cancelled, OmaConvertError
from . import formats
from .formats import IMAGE_FORMATS, VIDEO_FORMATS
from .optimizer import build_gif_profiles, representative_samples, size_text
from .probe import probe_media
from .publish import publish_folder_no_clobber, publish_no_clobber, work_directory



def dependencies():
    return {
        "ffmpeg": shutil.which("ffmpeg") is not None,
        "ffprobe": shutil.which("ffprobe") is not None,
        "gifsicle": shutil.which("gifsicle") is not None,
    }


def _default_output(input_path, fmt, requested_bytes):
    if requested_bytes:
        label = size_text(requested_bytes).replace(" ", "").replace(".", "-").lower()
        return input_path.with_name(f"{input_path.stem}-{label}.{fmt}")
    return input_path.with_suffix(f".{fmt}")


def _terminal_metadata(path, runner, colors=None):
    try:
        info = probe_media(path, runner)
    except Cancelled:
        raise
    except OmaConvertError as exc:
        # probe_media words its errors for the input; this is our own output.
        raise OmaConvertError("The converted file could not be verified and was not saved.",
                              exc.details or exc.message) from exc
    fields = {
        "path": str(Path(path).resolve()), "bytes": Path(path).stat().st_size,
        "width": info.width, "height": info.height, "fps": info.fps,
        "kind": info.kind,
    }
    if colors is not None:
        fields["colors"] = colors
    return fields


def _analyze_gif(runner, input_path, info, profiles, internal_target, workdir, gifsicle,
                 seek=0.0, clip=None):
    samples = representative_samples(info.duration)
    sample_duration = sum(length for _, length in samples)
    cache = {}

    def estimate(index):
        if index in cache:
            return cache[index]
        path = Path(workdir) / f"sample-{index}.gif"
        size = encode_gif(runner, input_path, path, profiles[index], info.duration, workdir,
                          samples=samples, gifsicle=gifsicle, stream_index=info.stream_index,
                          seek=seek, clip=clip, sdr=sdr_filter(info))
        estimated = max(size, int(size * info.duration / sample_duration))
        cache[index] = estimated
        runner.sink.emit("candidate", width=profiles[index].width, height=profiles[index].height,
                         fps=profiles[index].fps, colors=profiles[index].colors,
                         estimated_bytes=estimated, progress=len(cache) / (math.ceil(math.log2(len(profiles))) + 2))
        return estimated

    low, high = 0, len(profiles) - 1
    while low < high:
        middle = (low + high) // 2
        if estimate(middle) <= internal_target:
            high = middle
        else:
            low = middle + 1
    estimate(low)
    if low > 0:
        estimate(low - 1)
    runner.sink.emit("analyzing", progress=1.0)
    return low, cache


def _convert_gif(runner, input_path, info, output_temp, requested_bytes, preference, workdir, gifsicle,
                 seek=0.0, clip=None):
    profiles = build_gif_profiles(info.width, info.height, info.fps, preference)
    if not requested_bytes:
        raise AssertionError("quick preset must be selected by caller")
    internal_target = int(requested_bytes * 0.97)
    runner.sink.emit("analyzing", progress=0.0, target_bytes=requested_bytes,
                     internal_target_bytes=internal_target)
    chosen, estimates = _analyze_gif(runner, input_path, info, profiles, internal_target, workdir, gifsicle,
                                     seek, clip)
    attempt_indices = []
    index = chosen
    best = None
    smallest = None
    while len(attempt_indices) < 3:
        if index in attempt_indices:
            index = min(len(profiles) - 1, index + 1)
            if index in attempt_indices:
                break
        attempt_indices.append(index)
        profile = profiles[index]
        candidate_path = Path(workdir) / f"full-{len(attempt_indices)}.gif"
        candidate_path.unlink(missing_ok=True)
        size = encode_gif(runner, input_path, candidate_path, profile, info.duration, workdir,
                          pass_number=len(attempt_indices), passes=3, gifsicle=gifsicle, stream_index=info.stream_index,
                          seek=seek, clip=clip, sdr=sdr_filter(info))
        if smallest is None or size < smallest[0]:
            smallest = (size, profile)
        if size <= requested_bytes:
            if best is not None:
                best[2].unlink(missing_ok=True)
            best = (size, profile, candidate_path)
            if size < internal_target * 0.70 and index > 0 and len(attempt_indices) < 3:
                index -= 1
                continue
            break
        candidate_path.unlink(missing_ok=True)
        if best is not None:
            # A speculative one-step quality upgrade failed. The retained
            # fitting result is better than stepping below it.
            break
        ratio = size / internal_target
        index = min(len(profiles) - 1, index + max(1, math.ceil(math.log(ratio, 1.55))))
    if best is None and (not attempt_indices or attempt_indices[-1] != len(profiles) - 1):
        profile = profiles[-1]
        candidate_path = Path(workdir) / "full-fallback.gif"
        candidate_path.unlink(missing_ok=True)
        size = encode_gif(runner, input_path, candidate_path, profile, info.duration, workdir,
                          pass_number=4, passes=4, gifsicle=gifsicle, stream_index=info.stream_index,
                          seek=seek, clip=clip, sdr=sdr_filter(info))
        if smallest is None or size < smallest[0]:
            smallest = (size, profile)
        if size <= requested_bytes:
            if best is not None:
                best[2].unlink(missing_ok=True)
            best = (size, profile, candidate_path)
        else:
            candidate_path.unlink(missing_ok=True)
    if best is None:
        output_temp.unlink(missing_ok=True)
        smallest_bytes = smallest[0] if smallest else None
        raise OmaConvertError(
            f"This video cannot reasonably fit into {size_text(requested_bytes)} as a GIF.",
            f"Smallest result found: {smallest_bytes} bytes. Try a shorter clip, WebM, or MP4.",
        )
    if best[0] > requested_bytes or best[2].stat().st_size > requested_bytes:
        best[2].unlink(missing_ok=True)
        raise OmaConvertError("The converted GIF exceeded the requested maximum size.")
    output_temp.unlink(missing_ok=True)
    best[2].replace(output_temp)
    return best[1]


def _resolve_trim(info, trim_start, trim_end):
    """Validate the requested interval. Returns (seek, clip) or (0.0, None)."""
    if trim_start is None and trim_end is None:
        return 0.0, None
    if info.kind == "image":
        raise OmaConvertError(
            "Trimming applies to video, not still images.",
            "Choose a video input to select a time interval.",
        )
    if info.duration <= 0:
        raise OmaConvertError(
            "Trimming needs reliable duration metadata.",
            "Use Quick mode without trimming for this file.",
        )
    try:
        start = float(trim_start if trim_start is not None else 0.0)
        end = float(trim_end if trim_end is not None else info.duration)
    except (TypeError, ValueError):
        raise OmaConvertError("Trim positions must be a number of seconds.")
    if not math.isfinite(start) or not math.isfinite(end):
        raise OmaConvertError("Trim positions must be a number of seconds.")
    if start < 0:
        raise OmaConvertError("Trim start must be zero or later.")
    if start >= info.duration:
        raise OmaConvertError(
            "Trim start is beyond the end of this video.",
            f"Video duration: {info.duration:.2f} seconds.",
        )
    end = min(end, info.duration)
    if end <= start:
        raise OmaConvertError("Trim end must be later than trim start.")
    if end - start < 0.1:
        raise OmaConvertError(
            "The trimmed clip is too short.",
            "Select at least 0.1 seconds.",
        )
    return start, end - start


def _output_directory(output_dir):
    """Validate a destination folder before any heavy work starts."""
    folder = Path(output_dir).expanduser()
    if not folder.is_dir():
        raise OmaConvertError("The output folder does not exist.", str(folder))
    if not os.access(folder, os.W_OK | os.X_OK):
        raise OmaConvertError("The output folder is not writable.", str(folder))
    return folder.resolve()


def _check_sequence_request(fmt, output_path, requested_bytes, sequence_fps):
    if formats.normalize(fmt) != "png":
        raise OmaConvertError("A frame sequence is written as PNG; use --format png.")
    if output_path:
        raise OmaConvertError("A PNG sequence is a folder; choose it with --output-dir.")
    if requested_bytes:
        raise OmaConvertError("A PNG sequence has no size limit; remove --max-size.")
    if sequence_fps is not None and not (math.isfinite(sequence_fps) and sequence_fps > 0):
        raise OmaConvertError("Sequence frame rate must be a positive number.")


def _convert_sequence(runner, input_path, work, parent, seek, clip, sequence_fps):
    """Frames into `<stem>-frames/` next to the source (or in the output
    folder). Built in a hidden temporary folder, published only when
    complete; nothing is merged into or replaces an existing folder."""
    parent = Path(parent).resolve()
    if not os.access(parent, os.W_OK | os.X_OK):
        raise OmaConvertError("The output folder is not writable.", str(parent))
    try:
        with work_directory(parent) as directory:
            frames_dir = Path(directory) / "frames"
            count, rate = encode_png_sequence(runner, input_path, frames_dir, work,
                                              sequence_fps, seek, clip)
            first = min(frames_dir.glob("frame-*.png"))
            metadata = _terminal_metadata(first, runner)
            total = sum(path.stat().st_size for path in frames_dir.iterdir())
            runner.check_cancelled()
            _no_wider_than_source(frames_dir, input_path)
            published = publish_folder_no_clobber(
                frames_dir, parent / f"{input_path.stem}-frames",
                check_cancelled=runner.check_cancelled,
            )
            metadata.update(path=str(published), bytes=total, fps=rate, kind="sequence",
                            frames=count, first_frame=str(published / first.name))
            if clip is not None:
                metadata["trim_start"] = round(seek, 3)
                metadata["trim_end"] = round(seek + clip, 3)
            return metadata
    except PermissionError as exc:
        raise OmaConvertError("The output directory is not writable.", str(exc)) from exc
    except OSError as exc:
        if getattr(exc, "errno", None) == 28:
            raise OmaConvertError("Conversion failed because the destination disk is full.", str(exc)) from exc
        raise OmaConvertError("Could not create the output folder.", str(exc)) from exc


def _no_wider_than_source(path, source):
    """A result is never readable by more people than its source: drop the
    group/other bits the source does not grant (a 0600 video gives a 0600
    GIF). Folders keep their search bit only for those who may read."""
    try:
        source_mode = os.stat(source).st_mode
    except OSError:
        return
    keep = 0o700
    if source_mode & 0o040:
        keep |= 0o070
    if source_mode & 0o004:
        keep |= 0o007
    path = Path(path)
    for item in [path] + (sorted(path.iterdir()) if path.is_dir() else []):
        mode = item.stat().st_mode & 0o777
        if mode & ~keep:
            item.chmod(mode & keep)


def convert(runner, input_path, fmt, output_path, requested_bytes, preset, preference,
            trim_start=None, trim_end=None, output_dir=None, sequence=False, sequence_fps=None):
    if output_path and output_dir:
        raise OmaConvertError("Use either --output or --output-dir, not both.")
    if sequence:
        _check_sequence_request(fmt, output_path, requested_bytes, sequence_fps)
    folder = _output_directory(output_dir) if output_dir else None
    input_path = Path(input_path).expanduser()
    if not input_path.is_file():
        raise OmaConvertError("The input file does not exist or is not a regular file.", str(input_path))
    spec = formats.BY_ID.get(formats.normalize(fmt) or "")
    if spec is None:
        raise OmaConvertError("The requested output format is not supported.", str(fmt))
    fmt = spec.id
    # Cheap (ffmpeg -encoders/-muxers/-filters, cached) and before the probe,
    # so a missing encoder never costs an analysis or encode.
    # The full requirement (animated GIF filters, audio encoder) is known
    # only after the probe; here only what every input of this format needs.
    try:
        tools = formats.toolbox()
    except (OSError, subprocess.SubprocessError) as exc:
        raise OmaConvertError("Could not ask FFmpeg which formats it supports.", str(exc)) from exc
    missing = formats.missing_for(spec, tools, still=True)
    if missing:
        raise OmaConvertError(formats.unavailable_message(spec, missing), ", ".join(missing))
    info = probe_media(input_path, runner)
    runner.sink.emit("probe", **info.event_fields())
    still = fmt == "gif" and info.kind == "image"
    missing = formats.missing_for(spec, tools, audio=bool(info.audio) and fmt in VIDEO_FORMATS, still=still)
    if missing:
        audio = any(name in spec.audio_encoders for name in missing)
        raise OmaConvertError(formats.unavailable_message(spec, missing, audio=audio), ", ".join(missing))
    if info.kind == "image" and fmt in VIDEO_FORMATS:
        raise OmaConvertError(
            "A still image cannot be converted to a video format.",
            "Choose PNG, JPG, WebP, BMP, TIFF, or GIF.",
        )
    if (requested_bytes and info.kind == "video" and info.duration <= 0
            and fmt in VIDEO_FORMATS | {"gif"}):
        raise OmaConvertError(
            "A target size is unavailable because this animation has no reliable duration metadata.",
            "Use Quick mode for this file.",
        )
    seek, clip = _resolve_trim(info, trim_start, trim_end)
    if sequence:
        if info.kind == "image":
            raise OmaConvertError("A PNG sequence needs a video input.",
                                  "Choose PNG to save a still image.")
        work = replace(info, duration=clip) if clip is not None else info
        return _convert_sequence(runner, input_path, work, folder or input_path.parent,
                                 seek, clip, sequence_fps)
    # work carries the trimmed duration so bitrate, GIF samples, progress
    # and the size limit all apply to the selected interval. info stays
    # original for the probe event and source metadata.
    work = replace(info, duration=clip) if clip is not None else info
    if output_path:
        requested_output = Path(output_path).expanduser()
    else:
        requested_output = _default_output(input_path, fmt, requested_bytes)
        if folder is not None:
            requested_output = folder / requested_output.name
    if requested_output.suffix.lower().lstrip(".") not in spec.extensions:
        raise OmaConvertError(f"The output filename must end in .{fmt}.", str(requested_output))
    parent = requested_output.parent.resolve()
    if not parent.is_dir():
        raise OmaConvertError("The output directory does not exist.", str(parent))
    if not os.access(parent, os.W_OK | os.X_OK):
        raise OmaConvertError("The output folder is not writable.", str(parent))
    gifsicle = shutil.which("gifsicle")
    try:
        with work_directory(parent) as directory:
            temp_output = Path(directory) / f"result.{fmt}"
            if fmt in IMAGE_FORMATS and (fmt != "gif" or info.kind == "image"):
                if requested_bytes:
                    width, height = encode_image_target(
                        runner, input_path, temp_output, work, fmt, requested_bytes, seek)
                else:
                    width, height = encode_image_quick(
                        runner, input_path, temp_output, work, fmt, preset, seek)
                colors = None
            elif fmt == "gif":
                if requested_bytes:
                    profile = _convert_gif(runner, input_path, work, temp_output, requested_bytes,
                                           preference, directory, gifsicle, seek, clip)
                else:
                    profiles = build_gif_profiles(work.width, work.height, work.fps, preference)
                    index = {"high": 0, "balanced": min(4, len(profiles) - 1),
                             "small": min(8, len(profiles) - 1)}[preset]
                    profile = profiles[index]
                    encode_gif(runner, input_path, temp_output, profile, work.duration, directory,
                               gifsicle=gifsicle, stream_index=work.stream_index,
                               seek=seek, clip=clip, sdr=sdr_filter(work))
                colors = profile.colors
            elif requested_bytes:
                internal = int(requested_bytes * 0.97)
                runner.sink.emit("analyzing", progress=1.0, target_bytes=requested_bytes,
                                 internal_target_bytes=internal)
                width, height, fps, bitrate = encode_video_target(
                    runner, input_path, temp_output, work, fmt, internal, seek=seek, clip=clip)
                size = temp_output.stat().st_size
                if size > requested_bytes:
                    # Only the video part shrinks: scale it alone, or a clip
                    # whose sound is a big share of the budget misses again.
                    audio = TARGET_AUDIO_RATE * work.duration / 8 if work.audio else 0
                    corrected = int(bitrate * max(0, internal - audio) / max(1, size - audio) * 0.94)
                    temp_output.unlink()
                    width, height, fps, bitrate = encode_video_target(
                        runner, input_path, temp_output, work, fmt, internal, attempt=2,
                        bitrate_override=corrected, seek=seek, clip=clip)
                if temp_output.stat().st_size > requested_bytes:
                    size = temp_output.stat().st_size
                    temp_output.unlink()
                    raise OmaConvertError(
                        "The converted video could not meet the requested maximum size.",
                        f"Smallest result found: {size} bytes.",
                    )
                colors = None
            else:
                width, height, fps = encode_video_quick(
                    runner, input_path, temp_output, work, fmt, preset, seek, clip)
                colors = None
            # Validate the completed temporary file before it becomes user-visible.
            metadata = _terminal_metadata(temp_output, runner, colors)
            if requested_bytes and metadata["bytes"] > requested_bytes:
                raise OmaConvertError(
                    "The converted file exceeded the requested maximum size.",
                    f"Measured result: {metadata['bytes']} bytes.",
                )
            runner.check_cancelled()
            _no_wider_than_source(temp_output, input_path)
            published = publish_no_clobber(
                temp_output, requested_output, input_path,
                check_cancelled=runner.check_cancelled,
            )
            metadata["path"] = str(published)
            if clip is not None:
                metadata["trim_start"] = round(seek, 3)
                metadata["trim_end"] = round(seek + clip, 3)
            return metadata
    except PermissionError as exc:
        raise OmaConvertError("The output directory is not writable.", str(exc)) from exc
    except OSError as exc:
        if getattr(exc, "errno", None) == 28:
            raise OmaConvertError("Conversion failed because the destination disk is full.", str(exc)) from exc
        raise OmaConvertError("Could not create the output file.", str(exc)) from exc


def probe_all(runner, inputs):
    """Describe every input before a batch: one probe-item event each, with
    ok=False and a message for files that cannot be read."""
    for index, raw in enumerate(inputs):
        path = Path(raw).expanduser()
        try:
            if not path.is_file():
                raise OmaConvertError("The file does not exist or is not a regular file.", str(path))
            info = probe_media(path, runner)
        except Cancelled:
            raise
        except OmaConvertError as exc:
            runner.sink.emit("probe-item", index=index, ok=False, path=str(path),
                             message=exc.message, details=exc.details)
            continue
        runner.sink.emit("probe-item", index=index, ok=True, **info.event_fields())


def convert_batch(runner, inputs, fmt, requested_bytes, preset, preference,
                  output_dir=None, sequence=False, sequence_fps=None):
    """Convert several files with one recipe, one after another. A file that
    fails is reported (item-error) and skipped; cancelling stops the batch.
    Returns the summary for the final batch-complete event."""
    total = len(inputs)
    done = failed = 0
    before = after = 0
    outputs = []
    for index, raw in enumerate(inputs):
        runner.check_cancelled()
        source = str(Path(raw).expanduser())
        runner.sink.emit("item", index=index, total=total, path=source)
        try:
            result = convert(runner, source, fmt, None, requested_bytes, preset, preference,
                             output_dir=output_dir, sequence=sequence, sequence_fps=sequence_fps)
        except Cancelled:
            raise
        except OmaConvertError as exc:
            failed += 1
            runner.sink.emit("item-error", index=index, source=source, message=exc.message, details=exc.details)
            continue
        except Exception as exc:  # one odd file must not end the batch
            failed += 1
            runner.sink.emit("item-error", index=index, source=source,
                             message="OmaConvert could not convert this file.", details=str(exc))
            continue
        done += 1
        before += Path(source).stat().st_size
        after += int(result.get("bytes") or 0)
        outputs.append(result["path"])
        runner.sink.emit("item-complete", index=index, source=source, **result)
    if done == 0:
        raise OmaConvertError("None of the files could be converted.", f"{failed} of {total} failed.")
    return {"kind": "batch", "total": total, "done": done, "failed": failed,
            "bytes_before": before, "bytes_after": after, "paths": outputs, "path": outputs[0]}

