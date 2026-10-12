from dataclasses import dataclass
import math
import re


SIZE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*(KB|MB|GB)\s*$", re.IGNORECASE)


def parse_size(value):
    match = SIZE_RE.match(value or "")
    if not match:
        raise ValueError("Size must use decimal KB, MB, or GB, for example 50MB.")
    amount = float(match.group(1))
    if not math.isfinite(amount) or amount <= 0:
        raise ValueError("Maximum size must be greater than zero.")
    multiplier = {"KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000}[match.group(2).upper()]
    result = int(amount * multiplier)
    if result <= 0:
        raise ValueError("Maximum size is too small.")
    return result


def size_text(byte_count):
    """A target size the way it was typed: "200 KB", "50 MB", "1.5 MB"."""
    for unit, multiplier in (("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000)):
        if byte_count >= multiplier or unit == "KB":
            return f"{byte_count / multiplier:g} {unit}"


@dataclass(frozen=True)
class GifProfile:
    width: int
    height: int
    fps: float
    colors: int
    dither: str
    lossy: int


def _even_at_most(value, maximum):
    return max(2, min(int(value), int(maximum)) // 2 * 2)


def _dimensions(source_width, source_height, width):
    width = _even_at_most(width, source_width)
    height = _even_at_most(round(source_height * width / source_width), source_height)
    return width, height


def build_gif_profiles(source_width, source_height, source_fps, preference="balanced"):
    if preference not in {"motion", "balanced", "detail"}:
        raise ValueError("Preference must be motion, balanced, or detail.")
    source_width = _even_at_most(source_width, source_width)
    widths = []
    for value in [source_width, 1600, 1440, 1280, 1080, 960, 800, 720, 640, 560, 480, 400, 320]:
        value = _even_at_most(value, source_width)
        if value not in widths:
            widths.append(value)
    fps_values = []
    for value in [source_fps, 30, 25, 24, 20, 18, 15, 12, 10, 8, 6, 5]:
        value = min(float(value), float(source_fps))
        if value > 0 and all(abs(value - old) > 0.01 for old in fps_values):
            fps_values.append(value)
    fps_values.sort(reverse=True)
    colors = [256, 224, 192, 160, 128, 96, 64, 48, 32]
    levels = max(len(widths), len(fps_values), len(colors), 12)
    profiles = []
    seen = set()
    for level in range(levels):
        fraction = level / (levels - 1)
        wi = round(fraction * (len(widths) - 1))
        fi = round(fraction * (len(fps_values) - 1))
        if preference == "motion" and 0 < level < levels - 1:
            wi = min(len(widths) - 1, wi + 1)
            fi = max(0, fi - 1)
        elif preference == "detail" and 0 < level < levels - 1:
            wi = max(0, wi - 1)
            fi = min(len(fps_values) - 1, fi + 1)
        ci = round(fraction * (len(colors) - 1))
        width, height = _dimensions(source_width, source_height, widths[wi])
        fps = fps_values[fi]
        color_count = colors[ci]
        dither = "sierra2_4a" if fraction < 0.7 else "bayer"
        lossy = 0 if fraction < 0.72 else round((fraction - 0.7) / 0.3 * 80 / 20) * 20
        key = (width, height, round(fps, 3), color_count, dither, lossy)
        if key in seen:
            continue
        seen.add(key)
        profiles.append(GifProfile(width, height, fps, color_count, dither, lossy))
    minimum_width, minimum_height = _dimensions(source_width, source_height, min(320, source_width))
    minimum = GifProfile(minimum_width, minimum_height, min(5.0, source_fps), 32, "bayer", 120)
    if not profiles or profiles[-1] != minimum:
        profiles = [profile for profile in profiles if (profile.width, profile.fps, profile.colors) != (minimum.width, minimum.fps, 32)]
        profiles.append(minimum)
    return profiles


def representative_samples(duration):
    duration = float(duration)
    if duration <= 0:
        raise ValueError("Duration must be positive.")
    if duration <= 2.0:
        return [(0.0, duration)]
    length = min(1.0, duration / 5.0)
    starts = [0.0, max(0.0, duration / 2 - length / 2), max(0.0, duration - length)]
    return [(round(start, 6), round(min(length, duration - start), 6)) for start in starts]

