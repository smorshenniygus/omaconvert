"""Real constrained-size search across content classes, beyond an easy 5 MB cap."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg required')
class QualityFixtures(unittest.TestCase):
    def test_content_classes_fit_after_measured_search(self):
        fixtures = {
            'gradient': "nullsrc=s=480x270:r=20,geq=lum='X/W*255':cb=128:cr=128",
            'screen': 'color=c=0x202020:s=480x270:r=20,drawgrid=w=48:h=27:t=1:c=gray,drawbox=x=30:y=30:w=100:h=40:c=white:t=fill',
            'animation': 'testsrc2=s=480x270:r=20',
            'noise': "nullsrc=s=480x270:r=20,geq=lum='random(1)*255':cb='random(2)*255':cr='random(3)*255'",
        }
        with tempfile.TemporaryDirectory(prefix='omaconvert-quality-') as directory:
            folder = Path(directory)
            for name, filters in fixtures.items():
                with self.subTest(content=name):
                    source = folder / (name + '.mkv')
                    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', filters,
                                    '-t', '2', '-c:v', 'ffv1', str(source)], check=True, capture_output=True)
                    completed = subprocess.run([str(ROOT/'bin/omaconvert'), str(source), '--format', 'gif',
                                                '--max-size', '600KB'], capture_output=True, text=True, timeout=120)
                    events = [json.loads(line) for line in completed.stdout.splitlines()]
                    self.assertEqual(completed.returncode, 0, events)
                    result = events[-1]
                    self.assertEqual(result['event'], 'complete', events)
                    output = Path(result['path'])
                    self.assertLessEqual(output.stat().st_size, 600_000)
                    self.assertEqual(result['bytes'], output.stat().st_size)
                    self.assertLessEqual(result['width'], 480)
                    self.assertLessEqual(result['height'], 270)
                    self.assertLessEqual(result['fps'], 20.01)
                    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(output), '-f', 'null', '-'],
                                   check=True, capture_output=True)
                    self.assertFalse(list(folder.glob('.omaconvert-*')))
                    if name == 'noise':
                        self.assertTrue(result['width'] < 480 or result['fps'] < 20 or result['colors'] < 256,
                                        'constrained noisy content should require an adapted profile')
