"""Numbers that decide how OmaConvert behaves, with where each one comes from.

Change them here only; every module imports them from this file."""

# --- Target size --------------------------------------------------------
# Encoders aim below the limit: container overhead, the last GOP and VBV
# slack land the measured file 1-3 % off the bitrate estimate.
SIZE_HEADROOM = 0.97
# Share of the (budget minus audio) bitrate given to the video stream in a
# two-pass encode; the rest absorbs muxing overhead.
VIDEO_RATE_SHARE = 0.96
# A missed first attempt is rescaled with this extra margin so the second
# attempt lands under the limit rather than just on it.
RETRY_MARGIN = 0.94
# Below this video bitrate (bit/s) every frame size looks broken; the
# request is refused instead of producing an unwatchable file.
MIN_VIDEO_BITRATE = 60_000
# Sound of a target-size video (bit/s), budgeted before the video bitrate.
TARGET_AUDIO_RATE = 96_000
# Smallest bits per pixel per frame a two-pass encode is allowed to use
# before the resolution steps down. Tuned with VMAF on real 1080p footage:
# a smaller frame with enough bits beats a large starved one.
MIN_BITS_PER_PIXEL = 0.055

# --- Batches --------------------------------------------------------------
# Files of a still-image batch converted at once. A size search for one
# image keeps about one core busy; video encoders already use every core,
# so video and GIF batches stay one file at a time.
BATCH_IMAGE_JOBS = 3

# --- Process supervision -------------------------------------------------
# Probing and previews are bounded single reads: minutes of silence mean the
# tool hung (network mount, broken decoder), not a slow but healthy job.
PROBE_TIMEOUT = 120.0
# FFmpeg encodes report progress continuously; if the reported position does
# not advance for this long, the encoder is considered stuck. Override with
# OMACONVERT_STALL_TIMEOUT (seconds, 0 disables) for unusual hardware.
DEFAULT_STALL_TIMEOUT = 300.0

# --- Omarchy integration -------------------------------------------------
# Chat apps cap uploads at about this; smaller screen recordings need no
# "shrink it" offer.
OFFER_ABOVE_BYTES = 10_000_000
