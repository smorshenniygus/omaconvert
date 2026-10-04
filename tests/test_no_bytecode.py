"""The shell reloads every plugin when a file changes inside the plugin folder
(PluginRegistry localPluginChanged). Python bytecode caches written next to
lib/ on the first run of a new version would therefore unload the window a
moment after it opened. Entry points must never write into the plugin."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NoBytecodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-nobytecode-")
        self.addCleanup(self.tmp.cleanup)
        self.plugin = Path(self.tmp.name) / "omaconvert"
        ignore = shutil.ignore_patterns("__pycache__", "*.pyc", ".git", "tests", ".agents", ".claude",
                                        ".codex", ".hermes")
        shutil.copytree(ROOT, self.plugin, ignore=ignore, symlinks=True)
        self.env = {k: v for k, v in os.environ.items() if k != "PYTHONDONTWRITEBYTECODE"}
        self.env.pop("PYTHONPYCACHEPREFIX", None)

    def written(self):
        return sorted(str(p.relative_to(self.plugin)) for p in self.plugin.rglob("*")
                      if p.name == "__pycache__" or p.suffix == ".pyc")

    def test_backend_cli_writes_no_bytecode(self):
        subprocess.run([str(self.plugin / "bin/omaconvert"), "--version"], env=self.env,
                       capture_output=True, text=True, check=True)
        subprocess.run([str(self.plugin / "bin/omaconvert"), "--check"], env=self.env,
                       capture_output=True, text=True)
        self.assertEqual(self.written(), [])

    def test_open_wrapper_writes_no_bytecode(self):
        stub = Path(self.tmp.name) / "omarchy-shell"
        stub.write_text("#!/bin/sh\necho ok\n")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        env = dict(self.env, OMACONVERT_SHELL=str(stub))
        subprocess.run([str(self.plugin / "bin/omaconvert-open"), "/tmp/a.mp4"], env=env,
                       capture_output=True, text=True, check=True)
        self.assertEqual(self.written(), [])

    def test_open_with_toggle_writes_no_bytecode(self):
        with tempfile.TemporaryDirectory() as data:
            env = dict(self.env, XDG_DATA_HOME=data)
            for action in ("on", "off"):
                subprocess.run([str(self.plugin / "bin/omaconvert"), "--open-with", action], env=env,
                               capture_output=True, text=True, check=True)
        self.assertEqual(self.written(), [])


if __name__ == "__main__":
    unittest.main()
