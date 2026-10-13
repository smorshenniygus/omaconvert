#!/usr/bin/env python3
"""Deterministic backend for CliCall tests. How it behaves is the mode in its
own file name: tests link `cli_backend_<mode>.py` to this file."""

import json
import os
import signal
import sys
import time
from pathlib import Path


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}), flush=True)


def answer(args):
    """The one event a healthy backend sends for these arguments."""
    command = args[0] if args else ""
    word = args[1] if len(args) > 1 else ""
    if command == "--status":
        emit("status", version="9.9.9", dependencies={"ok": True, "gifsicle": True},
             open_with={"enabled": False, "current": True, "path": "/stub/omaconvert.desktop"},
             hotkey={"enabled": False, "available": True, "free": "SUPER + PERIOD"})
    elif command == "--capabilities":
        emit("capabilities", formats=[], menus={"video": [], "image": []}, input_extensions=[])
    elif command == "--open-with":
        emit("open-with", enabled=word == "on", current=True, path="/stub/omaconvert.desktop")
    elif command == "--hotkey":
        emit("hotkey", enabled=word == "on", available=True, keys="SUPER + PERIOD", free="SUPER + PERIOD")
    elif command == "--paste":
        emit("paste", kind="text", text="pasted words")
    else:
        emit("status", args=args)


def main():
    mode = Path(sys.argv[0]).stem.partition("cli_backend_")[2] or "ok"
    args = sys.argv[1:]
    if mode == "ok":
        answer(args)
    elif mode == "slow":
        time.sleep(0.4)
        answer(args)
    elif mode == "noisy":  # a warning before a good answer is not a failure
        print("DeprecationWarning: something old", flush=True)
        answer(args)
    elif mode == "empty":
        pass
    elif mode == "other":  # valid events, none of them the answer
        emit("dependencies", ok=True)
    elif mode == "malformed":
        print("this is not json", flush=True)
        print('{"event": 5}', flush=True)
    elif mode == "exit":
        print("Traceback (most recent call last):\nboom: the stub failed", file=sys.stderr, flush=True)
        sys.exit(3)
    elif mode == "hugeerr":
        print("x" * 20000, file=sys.stderr, flush=True)
        sys.exit(1)
    elif mode == "error":
        emit("error", message="Could not change the Open With entry.", details="read-only file system")
        sys.exit(2)
    elif mode == "late":  # a good answer, then a crash
        answer(args)
        sys.exit(1)
    elif mode == "crash":
        os.kill(os.getpid(), signal.SIGKILL)
    else:
        sys.exit(64)


if __name__ == "__main__":
    main()
