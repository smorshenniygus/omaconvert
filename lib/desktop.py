"""Omarchy integration around the window: paste from the clipboard, an
opt-in hotkey in the user's Hyprland bindings, and the offer to shrink a
finished screen recording. Nothing here runs unless the user acts, except
the recording offer, which the window starts when a recording ends."""
from datetime import datetime
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import time
from urllib.parse import unquote, urlparse

from .launcher import PLUGIN_ID, ROOT
from .publish import replace_text
from .tuning import (OFFER_ABOVE_BYTES, PASTE_IMAGE_BYTES, PASTE_LIST_BYTES, PASTE_TEXT_BYTES,
                     PASTE_TIMEOUT)

IMAGE_TYPES = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif", "image/bmp": "bmp"}
# Hyprland modmask bits.
SHIFT, CTRL, ALT, SUPER = 1, 4, 8, 64
HOTKEYS = [
    ("SUPER + SHIFT + PERIOD", SUPER | SHIFT, "period"),
    ("SUPER + ALT + C", SUPER | ALT, "c"),
    ("SUPER + CTRL + C", SUPER | CTRL, "c"),
    ("SUPER + ALT + PERIOD", SUPER | ALT, "period"),
]
BLOCK_START = "-- >>> OmaConvert hotkey (added from the OmaConvert window; remove it there)"
BLOCK_END = "-- <<< OmaConvert hotkey"


def _run(args, binary=False, timeout=5):
    try:
        return subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=not binary,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


# ── Clipboard ──────────────────────────────────────────────────────────────
class ClipboardTooLarge(Exception):
    pass


def _bounded(args, limit, timeout=None):
    """Output of `args`, or None when it is slower than `timeout` seconds or
    fails; ClipboardTooLarge past `limit` bytes. Reads in chunks and stops
    the reader at either bound: the clipboard owner can be any app."""
    try:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    data = bytearray()
    deadline = time.monotonic() + (PASTE_TIMEOUT if timeout is None else timeout)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            left = deadline - time.monotonic()
            if left <= 0 or not selector.select(left):
                return None
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            data += chunk
            if len(data) > limit:
                raise ClipboardTooLarge()
        return bytes(data) if process.wait(timeout=max(0.1, deadline - time.monotonic())) == 0 else None
    except subprocess.TimeoutExpired:
        return None
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()


def _read_clipboard(mime, limit):
    return _bounded(["wl-paste", "--no-newline", "--type", mime], limit)


def pictures_dir():
    env = os.environ.get("XDG_PICTURES_DIR")
    if env:
        return Path(env).expanduser()
    done = _run(["xdg-user-dir", "PICTURES"]) if shutil.which("xdg-user-dir") else None
    if done and done.returncode == 0 and done.stdout.strip():
        return Path(done.stdout.strip())
    return Path.home() / "Pictures"


def _existing_file(text):
    value = str(text or "").strip().splitlines()[0].strip() if str(text or "").strip() else ""
    if value.startswith("file://"):
        value = unquote(urlparse(value).path)
    value = os.path.expanduser(value)
    return value if value.startswith("/") and os.path.isfile(value) else ""


def paste():
    """What Ctrl+V should do in the window. An image is saved under
    ~/Pictures/OmaConvert so the result can sit next to it."""
    if not shutil.which("wl-paste"):
        return {"kind": "none", "reason": "wl-paste is not installed"}
    try:
        return _paste()
    except ClipboardTooLarge:
        return {"kind": "none", "reason": "too-large"}


def _paste():
    listed = _bounded(["wl-paste", "--list-types"], PASTE_LIST_BYTES)
    types = listed.decode("utf-8", "replace").split() if listed else []
    image = next((t for t in IMAGE_TYPES if t in types), None)
    if image:
        data = _read_clipboard(image, PASTE_IMAGE_BYTES)
        if data:
            folder = pictures_dir() / "OmaConvert"
            folder.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
            for number in range(1, 100):
                target = folder / f"pasted-{stamp}{'' if number == 1 else f'-{number}'}.{IMAGE_TYPES[image]}"
                try:
                    with open(target, "xb") as handle:
                        handle.write(data)
                    return {"kind": "file", "path": str(target), "paths": [str(target)], "source": "image"}
                except FileExistsError:
                    continue
    if "text/uri-list" in types:
        uris = (_read_clipboard("text/uri-list", PASTE_LIST_BYTES) or b"").decode("utf-8", "replace")
        paths = [p for p in (_existing_file(line) for line in uris.splitlines()) if p]
        if paths:
            return {"kind": "file", "path": paths[0], "paths": paths, "source": "file"}
    if any(t.startswith("text/plain") for t in types):
        value = (_read_clipboard("text/plain", PASTE_TEXT_BYTES) or b"").decode("utf-8", "replace")
        path = _existing_file(value)
        if path:
            return {"kind": "file", "path": path, "paths": [path], "source": "path"}
        if value:
            return {"kind": "text", "text": value}
    return {"kind": "none"}


# ── Hotkey ─────────────────────────────────────────────────────────────────
def bindings_path():
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return Path(config) / "hypr" / "bindings.lua"


def _block_pattern():
    return re.compile(r"\n?" + re.escape(BLOCK_START) + r".*?" + re.escape(BLOCK_END) + r"\n?", re.S)


def _taken():
    done = _run(["hyprctl", "binds", "-j"]) if shutil.which("hyprctl") else None
    try:
        binds = json.loads(done.stdout) if done and done.returncode == 0 else []
    except ValueError:
        binds = []
    return {(int(b.get("modmask", 0)), str(b.get("key", "")).lower()) for b in binds}


def _current_keys(text):
    match = _block_pattern().search(text)
    if not match:
        return None
    keys = re.search(r'o\.bind\("([^"]+)"', match.group(0))
    return keys.group(1) if keys else None


def hotkey_status():
    path = bindings_path()
    if not path.is_file():
        return {"enabled": False, "keys": None, "free": None, "available": False}
    keys = _current_keys(path.read_text(encoding="utf-8"))
    taken = _taken()
    free = next((label for label, mods, key in HOTKEYS if (mods, key) not in taken), None)
    return {"enabled": keys is not None, "keys": keys, "free": free, "available": True}


def set_hotkey(enabled):
    """Add or remove the marked block in ~/.config/hypr/bindings.lua, then
    reload Hyprland. Only the block between the markers is ever touched."""
    path = bindings_path()
    if not path.is_file():
        raise RuntimeError(f"{path} does not exist; this Omarchy has no Lua bindings file.")
    text = path.read_text(encoding="utf-8")
    current = _current_keys(text)
    if bool(enabled) == (current is not None):
        return hotkey_status()  # already so: no rewrite, no Hyprland reload
    if enabled:
        status = hotkey_status()
        if not status["free"]:
            raise RuntimeError("Every suggested key combination is already taken.")
        command = f"omarchy-shell shell toggle {PLUGIN_ID}"
        block = (f"\n{BLOCK_START}\n"
                 f'o.bind("{status["free"]}", "OmaConvert", "{command}")\n'
                 f"{BLOCK_END}\n")
        text = text.rstrip("\n") + "\n" + block
    else:
        text = _block_pattern().sub("\n", text).rstrip("\n") + "\n"
    # Replace the file a symlinked bindings.lua (stow, dotfile repos) points
    # to, so the link survives instead of becoming a plain file.
    target = path.resolve()
    replace_text(target, text, target.stat().st_mode)
    if shutil.which("hyprctl"):
        _run(["hyprctl", "reload"])
    return hotkey_status()


# ── Screen recording offer ────────────────────────────────────────────────
def _size_text(byte_count):
    return f"{byte_count / 1_000_000:.1f} MB"


def offer_recording(path):
    """Notify that a finished recording is larger than chat limits; clicking
    the notification opens it in OmaConvert."""
    target = Path(path)
    if not target.is_file():
        return {"offered": False, "reason": "missing"}
    size = target.stat().st_size
    if size <= OFFER_ABOVE_BYTES or not shutil.which("omarchy-notification-send"):
        return {"offered": False, "bytes": size}
    _run(["omarchy-notification-send", "-g", "󰕧", "-t", "15000",
          f"Recording is {_size_text(size)}",
          "Click to make it fit a chat limit in OmaConvert",
          "--exec", str(ROOT / "bin" / "omaconvert-open"), str(target)])
    return {"offered": True, "bytes": size}
