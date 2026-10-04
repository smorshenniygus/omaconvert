"""Exercise the real Quickshell Process lifecycle with a deterministic backend."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('qs'), 'Quickshell required')
class QmlLifecycle(unittest.TestCase):
    def test_replacement_request(self):
        with tempfile.TemporaryDirectory(prefix='omaconvert-qml-') as directory:
            folder = Path(directory)
            shutil.copytree(ROOT / 'services', folder / 'services')
            shutil.copytree(ROOT / 'tests/qml/helpers', folder / 'helpers')
            harness = (ROOT / 'tests/qml/ServiceHarness.qml').read_text().replace('../../services', 'services')
            (folder / 'shell.qml').write_text(harness)
            runtime = folder / 'runtime'
            runtime.mkdir(mode=0o700)
            environment = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                               XDG_RUNTIME_DIR=str(runtime), QT_QUICK_CONTROLS_STYLE='Basic')
            environment.pop('WAYLAND_DISPLAY', None)
            completed = subprocess.run(['qs', '-p', str(folder), '--no-color'], env=environment,
                                       text=True, capture_output=True, timeout=8)
            output = completed.stdout + completed.stderr
            self.assertEqual(completed.returncode, 0, output)
            self.assertIn('PASS latest queued selection wins', output)
            self.assertNotIn('FAIL', output)
