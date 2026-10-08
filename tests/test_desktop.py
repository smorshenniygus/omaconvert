"""Omarchy integration: paste from the clipboard, the opt-in hotkey block in
the user's Hyprland bindings, and the offer to shrink a finished screen
recording. External tools are stubbed on PATH; nothing touches the real
clipboard, Hyprland or notifications."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"


class DesktopTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-desktop-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.log = self.home / "calls.jsonl"
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:/usr/bin:/bin",
                        XDG_CONFIG_HOME=str(self.home / ".config"), XDG_PICTURES_DIR=str(self.home / "Pictures"))

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\nimport json, sys\n"
                        f"open({str(self.log)!r}, 'a').write(json.dumps([{name!r}] + sys.argv[1:]) + '\\n')\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def calls(self, name):
        if not self.log.exists():
            return []
        return [c[1:] for c in map(json.loads, self.log.read_text().splitlines()) if c[0] == name]

    def run_cli(self, *args):
        done = subprocess.run([str(CLI), *args], env=self.env, capture_output=True, text=True, timeout=20)
        events = [json.loads(line) for line in done.stdout.splitlines() if line.strip()]
        return done.returncode, events


class PasteTests(DesktopTestCase):
    def clipboard(self, types, payloads):
        self.stub("wl-paste", f"""
types = {types!r}
payloads = {payloads!r}
args = sys.argv[1:]
if args == ["--list-types"]:
    print("\\n".join(types)); sys.exit(0)
kind = args[args.index("--type") + 1] if "--type" in args else "text/plain"
data = payloads.get(kind)
if data is None: sys.exit(1)
sys.stdout.buffer.write(data.encode("latin-1"))
""")

    def test_image_is_saved_to_pictures_and_opened(self):
        self.clipboard(["image/png", "text/plain"], {"image/png": "\x89PNG\r\n\x1a\nfake"})
        code, events = self.run_cli("--paste")
        self.assertEqual(code, 0)
        event = events[-1]
        self.assertEqual((event["event"], event["kind"], event["source"]), ("paste", "file", "image"))
        path = Path(event["path"])
        self.assertEqual(path.parent, self.home / "Pictures" / "OmaConvert")
        self.assertTrue(path.name.startswith("pasted-") and path.suffix == ".png")
        self.assertEqual(path.read_bytes()[:4], b"\x89PNG")

    def test_copied_file_from_a_file_manager(self):
        video = self.home / "Видео [1] #2.mp4"
        video.write_bytes(b"x")
        uri = "file://" + "/".join(__import__("urllib.parse").parse.quote(p) for p in str(video).split("/"))
        self.clipboard(["text/uri-list", "text/plain"], {"text/uri-list": uri + "\r\n"})
        code, events = self.run_cli("--paste")
        self.assertEqual(events[-1]["kind"], "file")
        self.assertEqual(events[-1]["path"], str(video))

    def test_several_copied_files_are_all_returned(self):
        files = [self.home / name for name in ("a.png", "b.png")]
        for f in files:
            f.write_bytes(b"x")
        self.clipboard(["text/uri-list"], {"text/uri-list": "\r\n".join("file://" + str(f) for f in files)})
        _code, events = self.run_cli("--paste")
        self.assertEqual(events[-1]["paths"], [str(f) for f in files])

    def test_a_path_typed_as_text(self):
        photo = self.home / "photo.jpg"
        photo.write_bytes(b"x")
        self.clipboard(["text/plain;charset=utf-8", "text/plain"], {"text/plain": str(photo)})
        _code, events = self.run_cli("--paste")
        self.assertEqual((events[-1]["kind"], events[-1]["path"]), ("file", str(photo)))

    def test_plain_text_is_handed_back_for_the_line(self):
        self.clipboard(["text/plain"], {"text/plain": "gif 10mb"})
        _code, events = self.run_cli("--paste")
        self.assertEqual((events[-1]["kind"], events[-1]["text"]), ("text", "gif 10mb"))

    def test_empty_clipboard(self):
        self.clipboard([], {})
        _code, events = self.run_cli("--paste")
        self.assertEqual(events[-1]["kind"], "none")


class HotkeyTests(DesktopTestCase):
    def setUp(self):
        super().setUp()
        self.bindings = self.home / ".config" / "hypr" / "bindings.lua"
        self.bindings.parent.mkdir(parents=True)
        self.original = 'o.bind("SUPER + M", "rmpc", { tui = "rmpc", focus = true })\n'
        self.bindings.write_text(self.original)

    def hypr(self, taken):
        binds = [{"modmask": m, "key": k} for m, k in taken]
        self.stub("hyprctl", f"""
if sys.argv[1:3] == ["binds", "-j"]:
    print(json.dumps({binds!r}))
else:
    print("ok")
""")

    def test_on_adds_a_marked_block_on_a_free_combo_and_off_removes_it(self):
        self.hypr([(65, "C")])
        code, events = self.run_cli("--hotkey", "on")
        self.assertEqual(code, 0)
        self.assertEqual(events[-1]["enabled"], True)
        self.assertEqual(events[-1]["keys"], "SUPER + SHIFT + PERIOD")
        text = self.bindings.read_text()
        self.assertTrue(text.startswith(self.original))
        self.assertIn('o.bind("SUPER + SHIFT + PERIOD", "OmaConvert", "omarchy-shell shell toggle ', text)
        self.assertIn(["reload"], self.calls("hyprctl"))
        self.assertEqual(self.run_cli("--hotkey", "status")[1][-1]["enabled"], True)
        _code, events = self.run_cli("--hotkey", "off")
        self.assertEqual(events[-1]["enabled"], False)
        self.assertEqual(self.bindings.read_text(), self.original)

    def test_skips_taken_combinations(self):
        self.hypr([(65, "period"), (65, "C")])
        _code, events = self.run_cli("--hotkey", "on")
        self.assertEqual(events[-1]["keys"], "SUPER + ALT + C")

    def test_status_offers_the_first_free_combo(self):
        self.hypr([])
        _code, events = self.run_cli("--hotkey", "status")
        self.assertEqual((events[-1]["enabled"], events[-1]["free"]), (False, "SUPER + SHIFT + PERIOD"))

    def test_on_twice_keeps_one_block(self):
        self.hypr([])
        self.run_cli("--hotkey", "on")
        self.run_cli("--hotkey", "on")
        self.assertEqual(self.bindings.read_text().count("o.bind(\"SUPER + SHIFT + PERIOD\""), 1)

    def test_missing_bindings_file_is_a_clear_error(self):
        self.bindings.unlink()
        self.hypr([])
        code, events = self.run_cli("--hotkey", "on")
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]["event"], "error")
        self.assertFalse(self.bindings.exists())


class RecordingOfferTests(DesktopTestCase):
    def setUp(self):
        super().setUp()
        self.stub("omarchy-notification-send", "print('ok')\n")

    def recording(self, size):
        path = self.home / "Videos" / "screenrecording-2026-10-08_12-00-00.mp4"
        path.parent.mkdir(exist_ok=True)
        with path.open("wb") as handle:
            handle.truncate(size)
        return path

    def test_large_recording_gets_an_offer_that_opens_omaconvert(self):
        path = self.recording(48_200_000)
        code, events = self.run_cli("--offer-recording", str(path))
        self.assertEqual(code, 0)
        self.assertEqual(events[-1]["offered"], True)
        call = self.calls("omarchy-notification-send")[0]
        self.assertIn("48.2 MB", " ".join(call))
        exec_at = call.index("--exec")
        self.assertEqual(call[exec_at + 1:], [str(ROOT / "bin" / "omaconvert-open"), str(path)])

    def test_small_recording_is_left_alone(self):
        path = self.recording(4_000_000)
        _code, events = self.run_cli("--offer-recording", str(path))
        self.assertEqual(events[-1]["offered"], False)
        self.assertEqual(self.calls("omarchy-notification-send"), [])

    def test_missing_file_is_left_alone(self):
        _code, events = self.run_cli("--offer-recording", str(self.home / "gone.mp4"))
        self.assertEqual(events[-1]["offered"], False)


if __name__ == "__main__":
    unittest.main()
