"""HDR to SDR. Phone clips are HLG (iPhone) or PQ (HDR10); a file made to be
shared must be 8-bit BT.709, or it looks washed out wherever the colour tags
are ignored (chat previews, many players, our own thumbnails)."""
import subprocess

from . import formats

HDR_TRANSFERS = frozenset({"arib-std-b67", "smpte2084"})
# Mobius keeps in-range colours close to the original; hable darkens them.
_TONEMAP = ("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,"
            "tonemap=tonemap=mobius:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p")


def sdr_filter(info):
    """Filters that tone map `info`'s video to SDR BT.709, or "" when it is
    already SDR or this FFmpeg lacks zscale/tonemap (then nothing changes)."""
    if getattr(info, "transfer", "") not in HDR_TRANSFERS:
        return ""
    try:
        tools = formats.toolbox()
    except (OSError, subprocess.SubprocessError):
        return ""
    if tools is None or not {"zscale", "tonemap"} <= tools.filters:
        return ""
    return _TONEMAP


def chain(*filters):
    """Join filter strings, skipping empty ones."""
    return ",".join(item for item in filters if item)
