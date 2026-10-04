#!/usr/bin/env python3
"""Deterministic backend fixture for ConvertService lifecycle tests."""

import json
import sys
import time


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}), flush=True)


def main():
    emit("dependencies", ok=True, ffmpeg=True, ffprobe=True, gifsicle=True)
    if "--probe" not in sys.argv:
        return
    path = sys.argv[sys.argv.index("--probe") + 1]
    if path == "slow":
        time.sleep(0.8)
    emit("probe", path=path, duration=1, width=16, height=16, fps=1, bytes=1)


if __name__ == "__main__":
    main()
