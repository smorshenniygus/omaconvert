"""Omarchy integration around the window: paste from the clipboard, an
opt-in hotkey in the user's Hyprland bindings, and the offer to shrink a
finished screen recording. Nothing here runs unless the user acts, except
the recording offer, which the window starts when a recording ends."""
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import unquote, urlparse

from .launcher import PLUGIN_ID, ROOT

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
# Chat apps cap uploads at about this; smaller recordings need no offer.
OFFER_ABOVE_BYTES = 10_000_000


def _run(args, binary=False, timeout=5):
    try:
        return subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=not binary,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


# ── Clipboard ──────────────────────────────────────────────────────────────
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
    listed = _run(["wl-paste", "--list-types"])
    types = listed.stdout.split() if listed and listed.returncode == 0 else []
    image = next((t for t in IMAGE_TYPES if t in types), None)
    if image:
        data = _run(["wl-paste", "--no-newline", "--type", image], binary=True)
        if data and data.returncode == 0 and data.stdout:
            folder = pictures_dir() / "OmaConvert"
            folder.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
            for number in range(1, 100):
                target = folder / f"pasted-{stamp}{'' if number == 1 else f'-{number}'}.{IMAGE_TYPES[image]}"
                try:
                    with open(target, "xb") as handle:
                        handle.write(data.stdout)
                    return {"kind": "file", "path": str(target), "paths": [str(target)], "source": "image"}
                except FileExistsError:
                    continue
    if "text/uri-list" in types:
        uris = _run(["wl-paste", "--no-newline", "--type", "text/uri-list"])
        paths = [p for p in (_existing_file(line) for line in (uris.stdout.splitlines() if uris and uris.returncode == 0 else [])) if p]
        if paths:
            return {"kind": "file", "path": paths[0], "paths": paths, "source": "file"}
    if any(t.startswith("text/plain") for t in types):
        text = _run(["wl-paste", "--no-newline", "--type", "text/plain"])
        value = text.stdout if text and text.returncode == 0 else ""
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
    if enabled and current:
        return hotkey_status()
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
    temp = path.with_name(f".{path.name}.omaconvert-tmp")
    temp.write_text(text, encoding="utf-8")
    temp.chmod(path.stat().st_mode & 0o777)
    temp.replace(path)
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
