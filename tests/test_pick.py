"""bin/omaconvert-pick: Omarchy hands fullscreen to any newly focused window
(misc:on_focus_under_fullscreen = 1), so the portal file dialog takes it
over and the panel comes back merely maximized. The wrapper records the
panel's fullscreen state before the picker and restores it afterwards."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PICK = ROOT / "bin" / "omaconvert-pick"


class PickTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-pick-")
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name)
        self.log = self.bin / "hyprctl.log"
        self.state = self.bin / "state.json"

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\nimport json, sys\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def run_pick(self, before, after, picked="/home/u/Videos/a.mp4\n", code=0):
        # hyprctl: activewindow reports `before` until the picker ran, then `after`.
        self.state.write_text(json.dumps({"before": before, "after": after, "ran": False}))
        self.stub("hyprctl", f"""
state = json.load(open({str(self.state)!r}))
open({str(self.log)!r}, "a").write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["activewindow", "-j"]:
    print(json.dumps(state["after"] if state["ran"] else state["before"]))
else:
    print("ok")
""")
        self.stub("omarchy-file-select", f"""
state = json.load(open({str(self.state)!r}))
state["ran"] = True
json.dump(state, open({str(self.state)!r}, "w"))
sys.stdout.write({picked!r})
sys.exit({code})
""")
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        done = subprocess.run([str(PICK), "--title", "Choose", "--directory"], env=env,
                              capture_output=True, text=True, timeout=10)
        calls = [json.loads(l) for l in self.log.read_text().splitlines()] if self.log.exists() else []
        return done, [c for c in calls if c[0] == "dispatch"]

    def window(self, full, client):
        return {"address": "0xabc", "title": "OmaConvert", "fullscreen": full, "fullscreenClient": client}

    def test_restores_fullscreen_taken_by_the_dialog(self):
        done, dispatches = self.run_pick(self.window(2, 2), self.window(1, 1))
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout, "/home/u/Videos/a.mp4\n")
        self.assertIn(["dispatch", 'hl.dsp.focus({ window = "address:0xabc" })'], dispatches)
        self.assertIn(["dispatch", "hl.dsp.window.fullscreen_state({ internal = 2, client = 2 })"], dispatches)

    def test_leaves_an_unchanged_window_alone(self):
        _done, dispatches = self.run_pick(self.window(2, 2), self.window(2, 2))
        self.assertFalse(any("fullscreen_state" in c[1] for c in dispatches))

    def test_tiled_window_needs_nothing(self):
        _done, dispatches = self.run_pick(self.window(0, 0), self.window(0, 0))
        self.assertEqual(dispatches, [])

    def test_nothing_picked_keeps_exit_code(self):
        done, _ = self.run_pick(self.window(0, 0), self.window(0, 0), picked="", code=1)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stdout, "")

    def test_works_without_hyprland(self):
        self.stub("omarchy-file-select", "sys.stdout.write('/x.png\\n')\n")
        env = dict(os.environ, PATH=str(self.bin) + ":/usr/bin:/bin", HYPRLAND_INSTANCE_SIGNATURE="")
        (self.bin / "hyprctl").unlink(missing_ok=True)
        done = subprocess.run([str(PICK)], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual((done.returncode, done.stdout), (0, "/x.png\n"))


if __name__ == "__main__":
    unittest.main()
