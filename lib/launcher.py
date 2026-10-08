"""Desktop integration: open a file in the running OmaConvert window and
manage the .desktop entry that file managers use for "Open With".

Kept separate from the conversion CLI: nothing here touches media, and the
only side effects are one `omarchy-shell` IPC call or writing/removing the
user's own desktop entry, and only when asked. System defaults
(mimeapps.list) are never changed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess

from .formats import INPUT_MIME_TYPES

ROOT = Path(__file__).resolve().parents[1]
# The manifest is the only place the plugin id is written down.
PLUGIN_ID = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["id"]
TEMPLATE = ROOT / "assets" / "omaconvert.desktop"
# Marks entries this plugin wrote, so "off" never deletes someone else's file.
OWNER_KEY = "X-OmaConvert-Plugin"

# Media the backend can read; single-sourced with the picker filter.
MIME_TYPES = INPUT_MIME_TYPES

# Desktop Entry Specification, "The Exec key": these force an argument into
# double quotes; inside quotes, these four need a backslash.
_RESERVED = set(" \t\n\"'\\><~|&;$*?#()`")
_QUOTED_ESCAPES = set('"`$\\')


def payload_for(argument, cwd=None):
    """JSON payload for `shell summon`. Paths become absolute (symlinks are
    kept so the displayed name is the one the user clicked); file:// URIs are
    passed through for the window to decode; anything else is left for the
    window to reject with a readable message."""
    if argument is None or argument == "":
        return "{}"
    return json.dumps({"file": _payload_value(argument, cwd)}, ensure_ascii=False)


def _payload_value(argument, cwd=None):
    text = str(argument)
    if "://" in text:
        return text
    return os.path.abspath(os.path.join(cwd or os.getcwd(), os.path.expanduser(text)))


def payload_for_all(arguments, cwd=None):
    """One file keeps the {"file"} payload; several become {"files": [...]},
    which the window opens as a batch."""
    items = [a for a in (arguments or []) if a not in (None, "")]
    if len(items) <= 1:
        return payload_for(items[0] if items else None, cwd)
    return json.dumps({"files": [_payload_value(a, cwd) for a in items]}, ensure_ascii=False)


def open_in_shell(arguments, shell_command=None, cwd=None):
    """Summon the window with the given files: one opens normally, several
    open as a batch (the desktop entry passes the whole selection, %F)."""
    command = shell_command or os.environ.get("OMACONVERT_SHELL", "omarchy-shell")
    payload = payload_for_all(arguments, cwd)
    completed = subprocess.run([command, "shell", "summon", PLUGIN_ID, payload],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True)
    reply = (completed.stdout or "").strip()
    if completed.returncode != 0 or reply not in ("", "ok"):
        detail = (completed.stderr or reply or "no reply").strip()
        raise RuntimeError(
            "Could not open OmaConvert in the Omarchy shell. Is the plugin enabled "
            f"(omarchy plugin enable {PLUGIN_ID})? {detail}")
    return payload


def exec_argument(value):
    """Quote one argument for a desktop entry Exec key (before the file-level
    string escaping, which `desktop_value` applies)."""
    text = str(value)
    if not text or any(ch in _RESERVED for ch in text):
        text = '"' + "".join("\\" + ch if ch in _QUOTED_ESCAPES else ch for ch in text) + '"'
    # A literal percent must be doubled or it is read as a field code.
    return text.replace("%", "%%")


def desktop_value(text):
    """Escape a string value for a .desktop file."""
    return (str(text).replace("\\", "\\\\").replace("\n", "\\n")
            .replace("\t", "\\t").replace("\r", "\\r"))


def render_desktop_entry(template, open_command):
    """Fill the Exec, TryExec and MimeType lines of the bundled template.

    TryExec makes launchers and file managers hide the entry once the plugin
    folder is gone, so removing the plugin never leaves a broken "Open With"."""
    filled = {
        "Exec": desktop_value(exec_argument(open_command) + " %F"),
        "TryExec": desktop_value(str(open_command)),
        "MimeType": ";".join(MIME_TYPES) + ";",
        OWNER_KEY: desktop_value(PLUGIN_ID),
    }
    lines = []
    for line in template.splitlines():
        key = line.split("=", 1)[0] if "=" in line and not line.startswith("#") else None
        if key in filled:
            lines.append(f"{key}={filled.pop(key)}")
        elif not line.startswith("#"):
            lines.append(line)
    lines.extend(f"{key}={value}" for key, value in filled.items())
    return "\n".join(lines) + "\n"


def desktop_entry_path():
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return Path(data) / "applications" / f"{PLUGIN_ID}.desktop"


def _entry_lines(path):
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []


def _owned(path):
    return f"{OWNER_KEY}={PLUGIN_ID}" in _entry_lines(path)


def _refresh_database(folder):
    tool = shutil.which("update-desktop-database")
    if tool:
        subprocess.run([tool, str(folder)], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def open_with_status():
    """{"enabled", "path"}: enabled means our entry exists and launches this
    copy of the plugin (an entry left by a moved checkout counts as off)."""
    path = desktop_entry_path()
    lines = _entry_lines(path)
    launcher = desktop_value(str(ROOT / "bin" / "omaconvert-open"))
    enabled = f"{OWNER_KEY}={PLUGIN_ID}" in lines and f"TryExec={launcher}" in lines
    # Entries written before 1.2 passed one file (%f); a selection should
    # open as one batch (%F). The window rewrites an outdated entry.
    current = enabled and any(line.startswith("Exec=") and line.endswith(" %F") for line in lines)
    return {"enabled": enabled, "current": current, "path": str(path)}


def set_open_with(enabled):
    """Write or remove the user's desktop entry. Only a file this plugin wrote
    is replaced or removed; anything else at that path is left alone."""
    path = desktop_entry_path()
    if path.exists() and not _owned(path):
        raise RuntimeError(f"{path} was not created by OmaConvert; leaving it unchanged.")
    if enabled:
        path.parent.mkdir(parents=True, exist_ok=True)
        text = render_desktop_entry(TEMPLATE.read_text(encoding="utf-8"), ROOT / "bin" / "omaconvert-open")
        temp = path.with_name(f".{path.name}.tmp")
        temp.write_text(text, encoding="utf-8")
        temp.chmod(0o644)
        temp.replace(path)
    else:
        path.unlink(missing_ok=True)
    _refresh_database(path.parent)
    return open_with_status()
