"""Display orientation and sample-aspect-ratio regressions using actual MP4."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg required')
class OrientationTests(unittest.TestCase):
    def test_rotated_phone_video_and_nonsquare_pixels_preserve_shape(self):
        with tempfile.TemporaryDirectory(prefix='omaconvert-orientation-') as directory:
            folder = Path(directory)
            for sar in (1, 2):
                with self.subTest(sar=sar):
                    source = folder / f'base-{sar}.mp4'
                    rotated = folder / f'rotated-{sar}.mp4'
                    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=160x90:r=10',
                                    '-t', '1', '-vf', f'setsar={sar}', '-c:v', 'libx264', str(source)], check=True)
                    subprocess.run(['ffmpeg', '-v', 'error', '-display_rotation:v:0', '90', '-i', str(source),
                                    '-c', 'copy', str(rotated)], check=True)
                    for fmt in ('gif', 'mp4'):
                        completed = subprocess.run([str(ROOT/'bin/omaconvert'), str(rotated), '--format', fmt,
                                                    '--preset', 'high'], capture_output=True, text=True, timeout=30)
                        events = [json.loads(line) for line in completed.stdout.splitlines()]
                        self.assertEqual(completed.returncode, 0, events)
                        result = events[-1]
                        self.assertEqual(result['event'], 'complete', events)
                        self.assertAlmostEqual(result['width']/result['height'], 90/(160*sar), delta=0.02)
                        raw = subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', result['path']], text=True)
                        stream = json.loads(raw)['streams'][0]
                        self.assertIn(stream.get('sample_aspect_ratio', '1:1'), ('1:1', 'N/A'))
