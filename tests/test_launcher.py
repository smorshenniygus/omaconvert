"""DEV-06: desktop launcher payloads and the generated desktop entry."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

from lib import launcher

ROOT = Path(__file__).resolve().parents[1]
AWKWARD = "/tmp/Видео [5] #1 100% 'a' \"b\" $(echo nope);&.mp4"


class PayloadTests(unittest.TestCase):
    def test_awkward_absolute_path_round_trips(self):
        self.assertEqual(json.loads(launcher.payload_for(AWKWARD)), {"file": AWKWARD})

    def test_relative_path_becomes_absolute_without_resolving_symlinks(self):
        payload = json.loads(launcher.payload_for("clip #1.mp4", cwd="/tmp/link dir"))
        self.assertEqual(payload["file"], "/tmp/link dir/clip #1.mp4")

    def test_several_files_become_a_batch_payload(self):
        payload = json.loads(launcher.payload_for_all(["a.png", "/tmp/b c.jpg", "file:///tmp/d.gif"], cwd="/home/u"))
        self.assertEqual(payload, {"files": ["/home/u/a.png", "/tmp/b c.jpg", "file:///tmp/d.gif"]})
        self.assertEqual(json.loads(launcher.payload_for_all(["/tmp/one.mp4"])), {"file": "/tmp/one.mp4"})
        self.assertEqual(launcher.payload_for_all([]), "{}")

    def test_uris_pass_through_and_empty_shows_window(self):
        uri = "file:///tmp/a%20%231.mp4"
        self.assertEqual(json.loads(launcher.payload_for(uri))["file"], uri)
        self.assertEqual(launcher.payload_for(None), "{}")
        self.assertEqual(launcher.payload_for(""), "{}")


class ShellStubMixin:
    def make_stub(self, reply="ok", code=0):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-launch-")
        self.addCleanup(self.tmp.cleanup)
        self.log = Path(self.tmp.name) / "calls.jsonl"
        stub = Path(self.tmp.name) / "omarchy-shell"
        stub.write_text(
            "#!/usr/bin/env python3\n"
            "import json, sys\n"
            f"open({str(self.log)!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"print({reply!r})\n"
            f"sys.exit({code})\n")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        return str(stub)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]


class OpenInShellTests(ShellStubMixin, unittest.TestCase):
    def test_sequential_launches_each_summon_their_own_file(self):
        stub = self.make_stub()
        files = [AWKWARD, "/tmp/second.png", "/tmp/третий.gif"]
        for path in files:
            launcher.open_in_shell([path], shell_command=stub)
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        for call, path in zip(calls, files):
            self.assertEqual(call[:3], ["shell", "summon", launcher.PLUGIN_ID])
            self.assertEqual(json.loads(call[3]), {"file": path})

    def test_disabled_plugin_is_reported(self):
        stub = self.make_stub(reply="unknown")
        with self.assertRaises(RuntimeError) as caught:
            launcher.open_in_shell(["/tmp/a.mp4"], shell_command=stub)
        self.assertIn(f"omarchy plugin enable {launcher.PLUGIN_ID}", str(caught.exception))

    def test_cli_wrapper_passes_a_selection_as_one_batch(self):
        stub = self.make_stub()
        env = dict(os.environ, OMACONVERT_SHELL=stub)
        completed = subprocess.run([str(ROOT / "bin/omaconvert-open"), AWKWARD, "/tmp/second.mp4"],
                                   env=env, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(json.loads(self.calls()[0][3]), {"files": [AWKWARD, "/tmp/second.mp4"]})


class DesktopEntryTests(unittest.TestCase):
    COMMAND = "/home/Мой каталог/100% \"x\" $HOME\\b`q`/bin/omaconvert-open"

    def render(self, command=COMMAND):
        template = launcher.TEMPLATE.read_text()
        return launcher.render_desktop_entry(template, command)

    def test_exec_round_trips_through_glib(self):
        try:
            import gi
            gi.require_version("GLib", "2.0")
            from gi.repository import GLib
        except (ImportError, ValueError):
            self.skipTest("PyGObject is not available")
        keyfile = GLib.KeyFile()
        data = self.render()
        keyfile.load_from_data(data, len(data.encode()), GLib.KeyFileFlags.NONE)
        value = keyfile.get_string("Desktop Entry", "Exec")
        # GLib expands field codes on the unescaped string, then shell-parses.
        _ok, argv = GLib.shell_parse_argv(value.replace("%F", "FILE").replace("%%", "%"))
        self.assertEqual(argv, [self.COMMAND, "FILE"])

    def test_plain_path_is_unquoted_and_mime_types_listed(self):
        text = self.render("/home/u/.config/omarchy/plugins/omaconvert/bin/omaconvert-open")
        self.assertIn("Exec=/home/u/.config/omarchy/plugins/omaconvert/bin/omaconvert-open %F\n", text)
        self.assertIn("TryExec=/home/u/.config/omarchy/plugins/omaconvert/bin/omaconvert-open\n", text)
        mime = next(line for line in text.splitlines() if line.startswith("MimeType="))
        for kind in ("video/mp4", "video/webm", "image/png", "image/jpeg"):
            self.assertIn(kind + ";", mime)
        self.assertNotIn("Default", text)

    @unittest.skipUnless(shutil.which("desktop-file-validate"), "desktop-file-validate not installed")
    def test_rendered_entry_is_valid(self):
        with tempfile.NamedTemporaryFile("w", suffix=".desktop", delete=False) as handle:
            handle.write(self.render())
        self.addCleanup(os.unlink, handle.name)
        completed = subprocess.run(["desktop-file-validate", handle.name], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertNotIn("error", (completed.stdout + completed.stderr).lower())

    def open_with(self, action, data):
        env = dict(os.environ, XDG_DATA_HOME=data)
        completed = subprocess.run([str(ROOT / "bin/omaconvert"), "--open-with", action], env=env,
                                   capture_output=True, text=True)
        return completed.returncode, [json.loads(line) for line in completed.stdout.splitlines()]

    def test_open_with_on_status_off_round_trip(self):
        with tempfile.TemporaryDirectory() as data, tempfile.TemporaryDirectory() as config:
            entry = Path(data) / f"applications/{launcher.PLUGIN_ID}.desktop"
            self.assertEqual(self.open_with("status", data)[1][-1]["enabled"], False)
            code, events = self.open_with("on", data)
            self.assertEqual(code, 0)
            self.assertEqual(events[-1], {"event": "open-with", "enabled": True, "current": True, "path": str(entry)})
            text = entry.read_text()
            self.assertIn(f"Exec={ROOT}/bin/omaconvert-open %F", text)
            self.assertIn(f"TryExec={ROOT}/bin/omaconvert-open", text)
            self.assertEqual(self.open_with("status", data)[1][-1]["enabled"], True)
            self.assertEqual(self.open_with("off", data)[1][-1]["enabled"], False)
            self.assertFalse(entry.exists())
            self.assertFalse((Path(config) / "mimeapps.list").exists())

    def test_an_entry_from_before_batches_reports_outdated(self):
        with tempfile.TemporaryDirectory() as data:
            entry = Path(data) / f"applications/{launcher.PLUGIN_ID}.desktop"
            self.open_with("on", data)
            self.assertEqual(self.open_with("status", data)[1][-1]["current"], True)
            entry.write_text(entry.read_text().replace(" %F", " %f"))
            status = self.open_with("status", data)[1][-1]
            self.assertEqual((status["enabled"], status["current"]), (True, False))
            self.open_with("on", data)
            self.assertIn(" %F\n", entry.read_text())

    def test_open_with_never_touches_a_foreign_entry(self):
        with tempfile.TemporaryDirectory() as data:
            entry = Path(data) / f"applications/{launcher.PLUGIN_ID}.desktop"
            entry.parent.mkdir()
            entry.write_text("[Desktop Entry]\nName=Mine\n")
            for action in ("on", "off"):
                code, events = self.open_with(action, data)
                self.assertEqual(code, 2)
                self.assertEqual(events[-1]["event"], "error")
            self.assertEqual(entry.read_text(), "[Desktop Entry]\nName=Mine\n")
            self.assertEqual(self.open_with("status", data)[1][-1]["enabled"], False)


if __name__ == "__main__":
    unittest.main()
