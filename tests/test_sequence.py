import errno
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from lib import publish
from lib.backend import convert
from lib.errors import Cancelled, OmaConvertError
from lib.process import ProcessRunner


class Sink:
    def emit(self, *_args, **_fields):
        pass


def frames(folder):
    return sorted(path.name for path in Path(folder).glob("frame-*.png"))


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class SequenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.runner = ProcessRunner(Sink())
        # 2 s at 10 fps = 20 frames, with sound (ignored by PNG frames).
        self.video = self.root / "клип [1].mp4"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=s=160x90:r=10:d=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-shortest", str(self.video),
        ], check=True)

    def tearDown(self):
        self.directory.cleanup()

    def leftovers(self):
        return [p.name for p in self.root.iterdir() if p.name.startswith(".omaconvert-")]

    def test_every_frame_into_named_folder(self):
        result = convert(self.runner, self.video, "png", None, None, "balanced", "balanced", sequence=True)
        folder = self.root / "клип [1]-frames"
        self.assertEqual(Path(result["path"]), folder.resolve())
        self.assertEqual(result["kind"], "sequence")
        self.assertEqual(len(frames(folder)), 20)
        self.assertEqual(result["frames"], 20)
        self.assertEqual(frames(folder)[0], "frame-000001.png")
        self.assertEqual(Path(result["first_frame"]), folder.resolve() / "frame-000001.png")
        self.assertEqual((result["width"], result["height"]), (160, 90))
        self.assertEqual(result["bytes"], sum(p.stat().st_size for p in folder.iterdir()))
        self.assertEqual(self.leftovers(), [])

    def test_rate_and_trim_select_frames(self):
        result = convert(self.runner, self.video, "png", None, None, "balanced", "balanced",
                         0.5, 1.5, sequence=True, sequence_fps=5)
        self.assertEqual(result["frames"], 5)
        self.assertEqual(result["fps"], 5.0)
        self.assertEqual((result["trim_start"], result["trim_end"]), (0.5, 1.5))

    def test_rate_above_source_keeps_source_rate(self):
        result = convert(self.runner, self.video, "png", None, None, "balanced", "balanced",
                         sequence=True, sequence_fps=60)
        self.assertEqual(result["frames"], 20)

    def test_existing_folder_is_never_merged_or_replaced(self):
        taken = self.root / "клип [1]-frames"
        taken.mkdir()
        (taken / "mine.txt").write_text("keep")
        empty = self.root / "клип [1]-frames-2"
        empty.mkdir()
        result = convert(self.runner, self.video, "png", None, None, "balanced", "balanced", sequence=True)
        self.assertEqual(Path(result["path"]).name, "клип [1]-frames-3")
        self.assertEqual(sorted(p.name for p in taken.iterdir()), ["mine.txt"])
        self.assertEqual(list(empty.iterdir()), [])

    def test_output_dir(self):
        out = self.root / "out folder"
        out.mkdir()
        result = convert(self.runner, self.video, "png", None, None, "balanced", "balanced",
                         output_dir=out, sequence=True, sequence_fps=1)
        self.assertEqual(Path(result["path"]).parent, out.resolve())
        self.assertEqual(result["frames"], 2)

    def test_invalid_requests(self):
        cases = [
            dict(fmt="jpg"),
            dict(output_path=self.root / "x"),
            dict(requested_bytes=1_000_000),
            dict(sequence_fps=0),
            dict(sequence_fps=float("nan")),
        ]
        for case in cases:
            with self.subTest(case=case):
                arguments = dict(fmt="png", output_path=None, requested_bytes=None, sequence_fps=None)
                arguments.update(case)
                with self.assertRaises(OmaConvertError):
                    convert(self.runner, self.video, arguments["fmt"], arguments["output_path"],
                            arguments["requested_bytes"], "balanced", "balanced",
                            sequence=True, sequence_fps=arguments["sequence_fps"])
        self.assertEqual([p.name for p in self.root.iterdir()], [self.video.name])

    def test_image_input_is_rejected(self):
        image = self.root / "still.png"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                        "-i", "color=c=red:s=32x32", "-frames:v", "1", str(image)], check=True)
        with self.assertRaises(OmaConvertError):
            convert(self.runner, image, "png", None, None, "balanced", "balanced", sequence=True)

    def test_cancel_after_publish_retracts_folder(self):
        published = self.root / "клип [1]-frames"
        seen = {"published": False}

        def cancel_once_visible():
            # Cancellation lands right after the folder became visible.
            if published.exists():
                seen["published"] = True
                raise Cancelled("Cancelled")

        with mock.patch.object(self.runner, "check_cancelled", side_effect=cancel_once_visible):
            with self.assertRaises(Cancelled):
                convert(self.runner, self.video, "png", None, None, "balanced", "balanced", sequence=True)
        self.assertTrue(seen["published"])
        self.assertEqual([p.name for p in self.root.iterdir()], [self.video.name])

    def test_cli_reports_sequence(self):
        completed = subprocess.run([sys.executable, str(ROOT / "bin/omaconvert"), str(self.video),
                                    "--format", "png", "--sequence", "--sequence-fps", "2"],
                                   text=True, capture_output=True)
        events = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith("{")]
        complete = [e for e in events if e["event"] == "complete"]
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual(complete[0]["frames"], 4)
        bad = subprocess.run([sys.executable, str(ROOT / "bin/omaconvert"), str(self.video),
                              "--format", "png", "--sequence-fps", "2"], text=True, capture_output=True)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("--sequence-fps needs --sequence", bad.stdout)


class PublishFolderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def staged(self):
        staged = self.root / ".tmp" / "frames"
        staged.mkdir(parents=True)
        (staged / "frame-000001.png").write_bytes(b"x")
        return staged

    def test_fallback_without_renameat2(self):
        (self.root / "out").mkdir()
        staged = self.staged()
        with mock.patch.object(publish, "_rename_noreplace", side_effect=OSError(errno.ENOSYS, "no")):
            target = publish.publish_folder_no_clobber(staged, self.root / "out")
        self.assertEqual(target.name, "out-2")
        self.assertEqual(sorted(p.name for p in target.iterdir()), ["frame-000001.png"])
        self.assertEqual(list((self.root / "out").iterdir()), [])
        self.assertFalse(staged.exists())

    def test_noreplace_refuses_empty_folder(self):
        (self.root / "out").mkdir()
        staged = self.staged()
        with self.assertRaises(FileExistsError):
            publish._rename_noreplace(staged, self.root / "out")
        self.assertTrue((staged / "frame-000001.png").exists())


if __name__ == "__main__":
    unittest.main()
