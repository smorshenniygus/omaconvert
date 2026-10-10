from dataclasses import replace
from pathlib import Path
import math
import os
import shutil

from .color import chain, sdr_filter
from .errors import OmaConvertError
from .optimizer import size_text


def parse_ffmpeg_progress(line, duration):
    if duration <= 0:
        return None
    try:
        if line.startswith("out_time_us="):
            seconds = int(line.split("=", 1)[1]) / 1_000_000
        elif line.startswith("out_time_ms="):
            seconds = int(line.split("=", 1)[1]) / 1_000_000
        elif line.startswith("out_time="):
            hours, minutes, seconds_text = line.split("=", 1)[1].split(":")
            seconds = int(hours) * 3600 + int(minutes) * 60 + float(seconds_text)
        elif line == "progress=end":
            return 1.0
        else:
            return None
        return max(0.0, min(1.0, seconds / duration))
    except (ValueError, TypeError):
        return None


def _base_ffmpeg():
    return ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]


def _input_args(input_path, seek=0.0, clip=None):
    """Input seeking for a trimmed clip. Plain -i when untouched."""
    if (seek or 0) <= 0 and clip is None:
        return ["-i", str(input_path)]
    args = []
    if (seek or 0) > 0:
        args += ["-ss", f"{seek:.6f}"]
    if clip is not None:
        args += ["-t", f"{clip:.6f}"]
    return args + ["-i", str(input_path)]


def _vf(profile, sdr=""):
    # Tone mapping after the downscale: far cheaper than at source size.
    return chain(f"fps={profile.fps:.6g}", f"scale={profile.width}:{profile.height}:flags=lanczos",
                 sdr, "setsar=1")


def _sample_inputs(input_path, samples, seek=0.0, clip=None):
    args = []
    for start, length in samples:
        start += seek
        if clip is not None:
            if start >= seek + clip:
                continue
            length = min(length, seek + clip - start)
        args += ["-ss", f"{start:.6f}", "-t", f"{length:.6f}", "-i", str(input_path)]
    return args


def _sample_graph(profile, count, palette=False, stream_index=0, sdr=""):
    parts = [f"[{i}:{stream_index}]{_vf(profile, sdr)},setpts=PTS-STARTPTS[v{i}]" for i in range(count)]
    if count == 1:
        base = "[v0]"
    else:
        joined = "".join(f"[v{i}]" for i in range(count))
        parts.append(f"{joined}concat=n={count}:v=1:a=0[base]")
        base = "[base]"
    if palette:
        parts.append(f"{base}palettegen=max_colors={profile.colors}:stats_mode=diff[pal]")
    return ";".join(parts), "[pal]" if palette else base


def encode_gif(runner, input_path, output, profile, duration, workdir, samples=None,
               pass_number=1, passes=1, gifsicle=None, stream_index=0,
               seek=0.0, clip=None, sdr=""):
    palette = Path(workdir) / "palette.png"
    output = Path(output)
    if samples:
        graph, mapped = _sample_graph(profile, len(samples), palette=True, stream_index=stream_index, sdr=sdr)
        palette_args = _base_ffmpeg() + _sample_inputs(input_path, samples, seek, clip) + [
            "-filter_complex", graph, "-map", mapped, "-frames:v", "1", str(palette)
        ]
        runner.capture(palette_args, "FFmpeg could not generate a GIF palette.")
        graph, base = _sample_graph(profile, len(samples), palette=False, stream_index=stream_index, sdr=sdr)
        palette_index = len(samples)
        graph += f";{base}[{palette_index}:v]paletteuse=dither={profile.dither}:diff_mode=rectangle[out]"
        sample_duration = sum(length for _, length in samples)
        encode_args = _base_ffmpeg() + _sample_inputs(input_path, samples, seek, clip) + ["-i", str(palette),
            "-filter_complex", graph, "-map", "[out]", "-loop", "0",
            "-progress", "pipe:1", str(output)]
        measured_duration = sample_duration
    else:
        palette_args = _base_ffmpeg() + _input_args(input_path, seek, clip) + ["-map", f"0:{stream_index}", "-vf",
            f"{_vf(profile, sdr)},palettegen=max_colors={profile.colors}:stats_mode=diff",
            "-frames:v", "1", str(palette)]
        runner.capture(palette_args, "FFmpeg could not generate a GIF palette.")
        graph = f"[0:{stream_index}]{_vf(profile, sdr)}[video];[video][1:v]paletteuse=dither={profile.dither}:diff_mode=rectangle[out]"
        encode_args = _base_ffmpeg() + _input_args(input_path, seek, clip) + ["-i", str(palette),
            "-filter_complex", graph, "-map", "[out]", "-loop", "0",
            "-progress", "pipe:1", str(output)]
        measured_duration = duration
    progress_fields = {
        "pass": pass_number, "passes": passes,
        "width": profile.width, "height": profile.height, "fps": profile.fps,
    }
    runner.sink.emit("encoding", progress=0.0, **progress_fields)
    runner.ffmpeg(encode_args, measured_duration, **progress_fields)
    if gifsicle and profile.lossy > 0:
        optimized = output.with_name(output.stem + "-optimized.gif")
        runner.sink.emit("optimizing", progress=0.0)
        runner.capture([gifsicle, "-O3", f"--lossy={profile.lossy}", str(output), "-o", str(optimized)],
                       "gifsicle could not optimize the GIF.")
        if optimized.stat().st_size < output.stat().st_size:
            os.replace(optimized, output)
        else:
            optimized.unlink(missing_ok=True)
        runner.sink.emit("optimizing", progress=1.0)
    return output.stat().st_size


# Short side of a target-size video, largest first. Measured with VMAF on real
# 1080p footage (x264 two-pass): for a given bitrate the best-looking output is
# the largest of these that still gets about 0.055 bits per pixel. Bigger
# starves every pixel, smaller throws detail away.
_SHORT_SIDES = (2160, 1440, 1080, 720, 540, 480, 360, 240)
_MIN_BITS_PER_PIXEL = 0.055


def _video_shape(info, video_rate=None, fps=None):
    """Even output (width, height) for a video bitrate at the output frame
    rate; the source size when no bitrate is given. Never upscales."""
    width, height = info.width, info.height
    if video_rate:
        short, long = min(width, height), max(width, height)
        sides = [short] + [side for side in _SHORT_SIDES if side < short]
        for side in sides:
            other = round(long * side / short)
            if video_rate / (side * other * (fps or info.fps)) >= _MIN_BITS_PER_PIXEL:
                break
        width, height = (other, side) if width >= height else (side, other)
    return max(2, width // 2 * 2), max(2, height // 2 * 2)


def _quick_shape(info, cap):
    """Even (width, height) with the short side at most `cap`: 480p, 720p or
    1080p for landscape and portrait clips alike. Never upscales."""
    width, height = info.width, info.height
    short = min(width, height)
    if short > cap:
        width, height = round(width * cap / short), round(height * cap / short)
    return max(2, width // 2 * 2), max(2, height // 2 * 2)


def _image_dimensions(info, scale):
    return max(1, round(info.width * scale)), max(1, round(info.height * scale))


def encode_image(runner, input_path, output, info, fmt, width, height, quality=85,
                 pass_number=1, passes=1, seek=0.0):
    """Encode exactly one frame, preserving alpha where the format supports it."""
    output = Path(output)
    common = _input_args(input_path, seek)
    sdr = sdr_filter(info)
    if fmt == "jpg":
        # JPEG has no alpha channel. Composite explicitly instead of relying on
        # an encoder-dependent implicit black background.
        graph = (
            f"color=c=white:s={width}x{height}[bg];"
            f"[0:{info.stream_index}]{chain(f'scale={width}:{height}:flags=lanczos', sdr)},format=rgba[fg];"
            "[bg][fg]overlay=format=auto,format=yuvj420p[out]"
        )
        transform = ["-filter_complex", graph, "-map", "[out]"]
        codec = ["-c:v", "mjpeg", "-q:v", str(max(2, min(31, round((100 - quality) * 0.29 + 2))))]
    else:
        transform = ["-map", f"0:{info.stream_index}", "-vf",
                     chain(f"scale={width}:{height}:flags=lanczos", sdr, "setsar=1")]
        if fmt == "png":
            codec = ["-c:v", "png", "-compression_level", "9", "-pred", "mixed"]
        elif fmt == "webp":
            codec = ["-c:v", "libwebp", "-quality", str(quality), "-compression_level", "6"]
        elif fmt == "bmp":
            codec = ["-c:v", "bmp"]
        elif fmt == "tiff":
            codec = ["-c:v", "tiff", "-compression_algo", "deflate"]
        elif fmt == "gif":
            codec = ["-c:v", "gif"]
        else:
            raise OmaConvertError("Unsupported image output format.", fmt)
    progress_fields = {
        "pass": pass_number, "passes": passes,
        "width": width, "height": height, "fps": 0.0,
    }
    runner.sink.emit("encoding", progress=0.0, **progress_fields)
    runner.ffmpeg(_base_ffmpeg() + common + transform + codec
                  + ["-frames:v", "1", "-progress", "pipe:1", str(output)],
                  max(info.duration, 0.001), **progress_fields)
    return output.stat().st_size


def encode_image_quick(runner, input_path, output, info, fmt, preset, seek=0.0):
    scale, quality = {
        "high": (1.0, 95), "balanced": (1.0, 85), "small": (0.7, 72),
    }[preset]
    width, height = _image_dimensions(info, scale)
    encode_image(runner, input_path, output, info, fmt, width, height, quality, seek=seek)
    return width, height


def encode_image_target(runner, input_path, output, info, fmt, requested_bytes, seek=0.0):
    scales = (1.0, 0.85, 0.7, 0.55, 0.4, 0.3, 0.2, 0.12, 0.06)
    qualities = (95, 90, 84, 76, 66, 54, 42, 30, 20)
    runner.sink.emit("analyzing", progress=0.0, target_bytes=requested_bytes,
                     internal_target_bytes=int(requested_bytes * 0.97))
    smallest = None
    for number, (scale, quality) in enumerate(zip(scales, qualities), 1):
        width, height = _image_dimensions(info, scale)
        candidate = output.with_name(f"candidate-{number}.{fmt}")
        candidate.unlink(missing_ok=True)
        size = encode_image(runner, input_path, candidate, info, fmt, width, height,
                            quality, number, len(scales), seek)
        runner.sink.emit("candidate", width=width, height=height, fps=0.0,
                         estimated_bytes=size, progress=number / len(scales))
        if smallest is None or size < smallest[0]:
            if smallest is not None:
                smallest[3].unlink(missing_ok=True)
            smallest = (size, width, height, candidate)
        elif candidate != smallest[3]:
            candidate.unlink(missing_ok=True)
        if size <= requested_bytes:
            output.unlink(missing_ok=True)
            candidate.replace(output)
            if smallest is not None and smallest[3] != candidate:
                smallest[3].unlink(missing_ok=True)
            runner.sink.emit("analyzing", progress=1.0)
            return width, height
    smallest_size = smallest[0] if smallest else None
    if smallest is not None:
        smallest[3].unlink(missing_ok=True)
    raise OmaConvertError(
        f"This image cannot reasonably fit into {size_text(requested_bytes)}.",
        f"Smallest result found: {smallest_size} bytes.",
    )


# libvpx encodes one tile row at a time unless told otherwise: row
# multithreading made a 20 s 540p two-pass WebM 28% faster on 4 cores with
# the same output size and SSIM.
_VP9_THREADS = ("-row-mt", "1")


def encode_video_quick(runner, input_path, output, info, fmt, preset, seek=0.0, clip=None):
    settings = {
        "small": (480, 28, 36),
        "balanced": (720, 23, 30),
        "high": (1080, 18, 30),
    }
    cap, crf, fps_cap = settings[preset]
    width, height = _quick_shape(info, cap)
    fps = min(info.fps, fps_cap)
    vf = chain(f"fps={fps:.6g}", f"scale={width}:{height}:flags=lanczos", sdr_filter(info), "setsar=1")
    common = _input_args(input_path, seek, clip) + ["-vf", vf,
              "-map", f"0:{info.stream_index}", "-map", "0:a:0?", "-progress", "pipe:1"]
    if fmt in ("mp4", "mov", "mkv"):
        codec = ["-c:v", "libx264", "-preset", "medium", "-crf", str(crf),
                 "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k"]
        if fmt in ("mp4", "mov"):
            codec += ["-movflags", "+faststart"]
    else:
        codec = ["-c:v", "libvpx-vp9", *_VP9_THREADS, "-crf", str(crf + 4), "-b:v", "0",
                 "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "96k"]
    progress_fields = {"pass": 1, "passes": 1, "width": width, "height": height, "fps": fps}
    runner.sink.emit("encoding", progress=0.0, **progress_fields)
    runner.ffmpeg(_base_ffmpeg() + common + codec + [str(output)], info.duration,
                  **progress_fields)
    return width, height, fps


# Sound of a target-size video, budgeted before the video bitrate.
TARGET_AUDIO_RATE = 96_000


def encode_video_target(runner, input_path, output, info, fmt, internal_target, attempt=1,
                        bitrate_override=None, seek=0.0, clip=None, first_shape=None):
    """Two-pass encode at the bitrate for `internal_target` bytes. A retry
    passes `first_shape`, the (width, height) of attempt 1: at the same
    frame size its pass-1 statistics, which do not depend on the bitrate,
    are reused and only the second pass runs again."""
    audio_rate = TARGET_AUDIO_RATE if info.audio else 0
    total_rate = internal_target * 8 / info.duration
    video_rate = int(bitrate_override or ((total_rate - audio_rate) * 0.96))
    if video_rate < 60_000:
        raise OmaConvertError(
            "The requested size is too small for this video's duration.",
            "Try a larger target or a shorter clip.",
        )
    fps = min(info.fps, 30.0)
    width, height = _video_shape(info, video_rate, fps)
    reuse = attempt > 1 and first_shape == (width, height)
    passlog = str(Path(output).with_name(f"passlog-{1 if reuse else attempt}"))
    vf = chain(f"fps={fps:.6g}", f"scale={width}:{height}:flags=lanczos", sdr_filter(info), "setsar=1")
    # 8-bit 4:2:0 whatever the source (10-bit phone clips, 4:4:4 screen
    # recordings): High 10/4:4:4 H.264 and VP9 profile 1/2 do not play in
    # browsers and chat apps. Same in both passes so the pass log matches.
    if fmt in ("mp4", "mov", "mkv"):
        video_codec = ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"]
        audio_codec = ["-c:a", "aac", "-b:a", str(TARGET_AUDIO_RATE)]
        if fmt in ("mp4", "mov"):
            audio_codec += ["-movflags", "+faststart"]
    else:
        video_codec = ["-c:v", "libvpx-vp9", *_VP9_THREADS, "-deadline", "good", "-cpu-used", "2",
                       "-pix_fmt", "yuv420p"]
        audio_codec = ["-c:a", "libopus", "-b:a", str(TARGET_AUDIO_RATE)]
    first = _base_ffmpeg() + _input_args(input_path, seek, clip) + ["-map", f"0:{info.stream_index}", "-vf", vf,
        *video_codec, "-b:v", str(video_rate), "-pass", "1", "-passlogfile", passlog,
        "-an", "-f", "null", "-progress", "pipe:1", os.devnull]
    second = _base_ffmpeg() + _input_args(input_path, seek, clip) + ["-map", f"0:{info.stream_index}", "-map", "0:a:0?", "-vf", vf,
        *video_codec, "-b:v", str(video_rate), "-pass", "2", "-passlogfile", passlog,
        *audio_codec, "-progress", "pipe:1", str(output)]
    for number, args in ((2, second),) if reuse else ((1, first), (2, second)):
        progress_fields = {
            "pass": number, "passes": 2, "attempt": attempt,
            "width": width, "height": height, "fps": fps,
        }
        runner.sink.emit("encoding", progress=0.0, **progress_fields)
        runner.ffmpeg(args, info.duration, **progress_fields)
    return width, height, fps, video_rate


def encode_png_sequence(runner, input_path, folder, info, fps=None, seek=0.0, clip=None):
    """Write the frames of a video as frame-000001.png, … into a new `folder`.

    Every decoded frame by default; `fps` resamples to that rate (never above
    the source rate). Alpha is kept. Returns (frame count, rate)."""
    folder = Path(folder)
    folder.mkdir()
    rate = min(float(fps), info.fps) if fps and info.fps > 0 else float(fps or info.fps or 0)
    filters = [f"fps={rate:.6g}"] if fps else []
    filters += [sdr_filter(info), "setsar=1"]
    progress_fields = {"pass": 1, "passes": 1, "width": info.width, "height": info.height, "fps": rate}
    runner.sink.emit("encoding", progress=0.0, **progress_fields)
    runner.ffmpeg(_base_ffmpeg() + _input_args(input_path, seek, clip)
                  + ["-map", f"0:{info.stream_index}", "-vf", chain(*filters),
                     "-c:v", "png", "-start_number", "1", "-progress", "pipe:1",
                     str(folder / "frame-%06d.png")],
                  info.duration, **progress_fields)
    count = sum(1 for _ in folder.glob("frame-*.png"))
    if count == 0:
        raise OmaConvertError("FFmpeg wrote no frames for this video.")
    return count, rate
