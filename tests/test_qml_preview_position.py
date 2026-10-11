"""Verify preview seeks through Quickshell and the real backend in isolation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("qs") and shutil.which("ffmpeg"), "Quickshell and FFmpeg required")
class PreviewPosition(unittest.TestCase):
    def run_positions(self, first):
        with tempfile.TemporaryDirectory(prefix="oma-pos-") as directory:
            folder = Path(directory)
            shutil.copytree(ROOT / "services", folder / "services")
            harness = (ROOT / "tests/qml/PreviewPositionHarness.qml").read_text().replace("../../services", "services")
            (folder / "shell.qml").write_text(harness)
            (folder / "runtime").mkdir(mode=0o700)
            video = folder / "clip.mkv"
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-f", "lavfi", "-i", "color=red:s=64x64:r=10:d=1",
                            "-f", "lavfi", "-i", "color=blue:s=64x64:r=10:d=3",
                            "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
                            "-map", "[v]", "-c:v", "ffv1", str(video)], check=True)
            # Capture each real generated image before the fixed slot is overwritten.
            proxy = folder / "capture.py"
            proxy.write_text("""import os, pathlib, shutil, subprocess, sys
args = sys.argv[1:]
result = subprocess.run([sys.executable, os.environ['OMACONVERT_REAL_CLI']] + args)
if result.returncode == 0 and '--preview' in args:
    folder = pathlib.Path(__file__).parent
    index = len(list(folder.glob('frame-*.png')))
    shutil.copyfile(args[args.index('--preview-output') + 1], folder / f'frame-{index}.png')
sys.exit(result.returncode)
""")
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="",
                       XDG_RUNTIME_DIR=str(folder / "runtime"), XDG_CACHE_HOME=str(folder / "cache"),
                       OMACONVERT_TEST_CLI=str(proxy), OMACONVERT_REAL_CLI=str(ROOT / "bin/omaconvert"),
                       OMACONVERT_TEST_INPUT=str(video), OMACONVERT_TEST_FIRST=first)
            env.pop("WAYLAND_DISPLAY", None)
            result = subprocess.run(["qs", "-p", str(folder), "--no-color"], env=env,
                                    text=True, capture_output=True, timeout=12)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("PASS explicit zero refreshed the preview", output)
            self.assertNotIn("FAIL", output)
            colors = []
            for frame in sorted(folder.glob("frame-*.png")):
                rgb = subprocess.check_output(["ffmpeg", "-hide_banner", "-loglevel", "error",
                                               "-i", str(frame), "-vf", "scale=1:1",
                                               "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
                colors.append(tuple(rgb))
            self.assertEqual(len(colors), 2, colors)
            self.assertGreater(colors[0][2], colors[0][0] + 100, colors)  # later = blue
            self.assertGreater(colors[1][0], colors[1][2] + 100, colors)  # zero = red

    def test_default_thumbnail_then_explicit_zero(self):
        self.run_positions("default")

    def test_nonzero_thumbnail_then_explicit_zero(self):
        self.run_positions("nonzero")
