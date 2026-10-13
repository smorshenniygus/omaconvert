"""Only media containers are opened, and only from local files: a file that
FFmpeg would treat as a script or a playlist is refused when it is first
read (the probe that runs as soon as a file is chosen), with a clear
message, while every supported format still opens."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"


class InputSourceTests(unittest.TestCase):
    def test_every_ffmpeg_input_goes_through_the_allowlist(self):
        offenders = []
        for path in (ROOT / "lib").glob("*.py"):
            if path.name == "inputs.py":
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if re.search(r'"-i"', line):
                    offenders.append(f"{path.name}:{number}")
        self.assertEqual(offenders, [])


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class InputAllowlistTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-inputs-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def probe(self, path):
        done = subprocess.run([str(CLI), "--probe", str(path)], capture_output=True, text=True, timeout=60)
        return json.loads(done.stdout.strip().splitlines()[-1])

    def test_script_and_playlist_names_are_refused(self):
        # Plain text under a name FFmpeg maps to its AviSynth demuxer by
        # extension: refused by the allowlist before that demuxer opens it.
        path = self.root / "notes.avs"
        path.write_text("plain text, not media\n")
        event = self.probe(path)
        self.assertEqual(event["event"], "error")
        self.assertIn("not a video or image", event["message"])
        # A playlist-shaped text file under a media name is not media either.
        path = self.root / "list.mp4"
        path.write_text("ffconcat version 1.0\n")
        self.assertEqual(self.probe(path)["event"], "error")

    def test_supported_formats_still_open(self):
        clips = {"mp4": [], "mkv": [], "webm": [], "avi": [], "mov": [], "ts": [], "flv": [], "ogv": [],
                 "wmv": [], "mpg": ["-c:v", "mpeg2video", "-f", "vob"]}
        stills = ("png", "jpg", "webp", "bmp", "tiff", "gif")
        made = []
        for ext, extra in clips.items():
            path = self.root / f"clip.{ext}"
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                            "testsrc2=s=160x120:d=1:r=10", *extra, str(path)], check=True)
            made.append(path)
        for ext in stills:
            path = self.root / f"still.{ext}"
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                            "testsrc2=s=160x120", "-frames:v", "1", str(path)], check=True)
            made.append(path)
        for path in made:
            event = self.probe(path)
            self.assertEqual(event["event"], "probe", f"{path.name}: {event}")


if __name__ == "__main__":
    unittest.main()
