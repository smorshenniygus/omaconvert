"""Exercise the real Quickshell Process lifecycle with a deterministic backend."""
import os
import stat
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


@unittest.skipUnless(shutil.which('qs') and shutil.which('ffmpeg'), 'Quickshell and FFmpeg required')
class PreviewCache(unittest.TestCase):
    """The window's thumbnail is owner-only on disk and gone once cleared."""

    def run_harness(self, folder, clear):
        image = folder / 'secret.png'
        if not image.exists():
            subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi',
                            '-i', 'testsrc2=s=320x200', '-frames:v', '1', str(image)], check=True)
            image.chmod(0o600)
        environment = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                           XDG_RUNTIME_DIR=str(folder / 'runtime'), XDG_CACHE_HOME=str(folder / 'cache'),
                           OMACONVERT_TEST_CLI=str(ROOT / 'bin' / 'omaconvert'),
                           OMACONVERT_TEST_INPUT=str(image), OMACONVERT_TEST_CLEAR='1' if clear else '0')
        environment.pop('WAYLAND_DISPLAY', None)
        completed = subprocess.run(['qs', '-p', str(folder), '--no-color'], env=environment,
                                   text=True, capture_output=True, timeout=20,
                                   preexec_fn=lambda: os.umask(0o022))
        output = completed.stdout + completed.stderr
        self.assertNotIn('FAIL', output)
        self.assertIn('READY', output)
        return folder / 'cache' / 'omaconvert' / 'previews' / 'src-preview.png'

    def test_preview_is_private_and_cleared(self):
        with tempfile.TemporaryDirectory(prefix='omaconvert-qml-') as directory:
            folder = Path(directory)
            shutil.copytree(ROOT / 'services', folder / 'services')
            harness = (ROOT / 'tests/qml/PreviewHarness.qml').read_text().replace('../../services', 'services')
            (folder / 'shell.qml').write_text(harness)
            (folder / 'runtime').mkdir(mode=0o700)
            cached = self.run_harness(folder, clear=False)
            self.assertTrue(cached.is_file())
            self.assertEqual(stat.S_IMODE(cached.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(cached.parent.stat().st_mode), 0o700)
            cached = self.run_harness(folder, clear=True)
            self.assertFalse(cached.exists())
