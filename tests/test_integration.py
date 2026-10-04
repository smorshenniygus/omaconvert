"""End-to-end CLI checks using small media made by the installed FFmpeg.

These tests deliberately inspect files and JSON-lines rather than implementation
details, so they describe the public contract of ``bin/omaconvert``.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"
FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")
UNICODE_NAME = "Отпуск на море_день 5 [0123456789abcdef0123456789abcdef].mp4"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ffprobe_json(path: Path) -> dict:
    completed = subprocess.run(
        [FFPROBE, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        check=True,
        text=True,
        capture_output=True,
    )
    return json.loads(completed.stdout)


@unittest.skipUnless(FFMPEG and FFPROBE, "ffmpeg and ffprobe are required for integration tests")
class OmaConvertIntegrationTests(unittest.TestCase):
    """Black-box tests for real conversion jobs; no mocks or fake media."""

    @classmethod
    def setUpClass(cls) -> None:
        if not CLI.is_file():
            raise AssertionError(f"OmaConvert CLI is missing: {CLI}")
        if not os.access(CLI, os.X_OK):
            raise AssertionError(f"OmaConvert CLI is not executable: {CLI}")
        cls.fixture_dir = tempfile.TemporaryDirectory(prefix="omaconvert-fixtures-")
        cls.source = Path(cls.fixture_dir.name) / "source.mp4"
        cls._make_video(cls.source, duration=3, size="320x180")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fixture_dir.cleanup()

    @staticmethod
    def _make_video(destination: Path, *, duration: int, size: str) -> None:
        subprocess.run(
            [
                FFMPEG,
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"testsrc2=size={size}:rate=15",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=44100",
                "-t",
                str(duration),
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-shortest",
                str(destination),
            ],
            check=True,
            text=True,
            capture_output=True,
        )

    def setUp(self) -> None:
        self.work = tempfile.TemporaryDirectory(prefix="omaconvert-integration-")
        self.addCleanup(self.work.cleanup)
        self.work_path = Path(self.work.name)

    def run_cli(self, *args: str, timeout: float = 90) -> tuple[subprocess.CompletedProcess[str], list[dict]]:
        temp_root = self.work_path / "tool-tmp"
        temp_root.mkdir(exist_ok=True)
        environment = os.environ.copy()
        environment["TMPDIR"] = str(temp_root)
        completed = subprocess.run(
            [str(CLI), *map(str, args)],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        events: list[dict] = []
        for line in completed.stdout.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError as exc:
                self.fail(f"stdout must contain JSON-lines only; got {line!r}: {exc}")
            self.assertIsInstance(event, dict, "each JSON line must be an object")
            self.assertIn("event", event, "each event must identify its event type")
            events.append(event)
        self.assertTrue(events, f"CLI produced no JSON events; stderr: {completed.stderr}")
        self.assertFalse(
            any(temp_root.rglob("*")),
            f"CLI left temporary files in its test-owned TMPDIR: {list(temp_root.rglob('*'))}",
        )
        self.assertFalse(list(self.work_path.glob(".omaconvert-*")), "output-directory temporary files were not cleaned")
        return completed, events

    def assert_complete(self, completed: subprocess.CompletedProcess[str], events: list[dict]) -> dict:
        self.assertEqual(completed.returncode, 0, completed.stderr)
        complete = [event for event in events if event["event"] == "complete"]
        self.assertEqual(len(complete), 1, events)
        self.assertIn("path", complete[0])
        self.assertIn("bytes", complete[0])
        return complete[0]

    def test_probe_emits_json_metadata_for_media(self) -> None:
        completed, events = self.run_cli("--probe", self.source)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        probe = [event for event in events if event["event"] == "probe"]
        self.assertEqual(len(probe), 1, events)
        self.assertGreater(probe[0]["duration"], 0)
        self.assertEqual(probe[0]["width"], 320)
        self.assertEqual(probe[0]["height"], 180)

    def test_gif_is_decodable_and_never_exceeds_decimal_5mb(self) -> None:
        output = self.work_path / "target.gif"
        completed, events = self.run_cli(
            self.source, "--format", "gif", "--max-size", "5MB", "--preset", "balanced", "--output", output
        )
        result = self.assert_complete(completed, events)
        produced = Path(result["path"])
        self.assertTrue(produced.is_file())
        self.assertLessEqual(produced.stat().st_size, 5_000_000)
        self.assertEqual(result["bytes"], produced.stat().st_size)
        streams = ffprobe_json(produced)["streams"]
        self.assertTrue(any(stream["codec_type"] == "video" for stream in streams))

    def test_unicode_bracketed_input_filename_is_preserved_and_converted(self) -> None:
        source = self.work_path / UNICODE_NAME
        shutil.copyfile(self.source, source)
        before = sha256(source)
        output = self.work_path / "unicode.gif"
        completed, events = self.run_cli(
            source, "--format", "gif", "--max-size", "5MB", "--preset", "small", "--output", output
        )
        result = self.assert_complete(completed, events)
        produced = Path(result["path"])
        self.assertTrue(produced.is_file())
        self.assertEqual(before, sha256(source), "conversion must never alter its source")
        self.assertTrue(any(s["codec_type"] == "video" for s in ffprobe_json(produced)["streams"]))

    def test_collision_keeps_existing_destination_and_source_unchanged(self) -> None:
        output = self.work_path / "already-there.gif"
        original_destination = b"do not overwrite this existing file"
        output.write_bytes(original_destination)
        source_before = sha256(self.source)
        completed, events = self.run_cli(
            self.source, "--format", "gif", "--max-size", "5MB", "--preset", "small", "--output", output
        )
        result = self.assert_complete(completed, events)
        produced = Path(result["path"])
        self.assertEqual(output.read_bytes(), original_destination)
        self.assertNotEqual(produced, output, "collision must select a safe new name")
        self.assertTrue(produced.is_file())
        self.assertEqual(source_before, sha256(self.source))

    def test_impossible_gif_target_reports_error_without_successful_oversize_file(self) -> None:
        output = self.work_path / "impossible.gif"
        completed, events = self.run_cli(
            self.source, "--format", "gif", "--max-size", "0.000001MB", "--preset", "high", "--output", output
        )
        self.assertNotEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(any(event["event"] == "complete" for event in events), events)
        errors = [event for event in events if event["event"] == "error"]
        self.assertEqual(len(errors), 1, events)
        self.assertTrue(errors[0].get("message"), errors)
        self.assertFalse(output.exists(), "an impossible target must not publish an oversized file")

    def test_mp4_and_webm_outputs_are_decodable_and_retain_audio(self) -> None:
        for fmt in ("mp4", "webm"):
            with self.subTest(format=fmt):
                output = self.work_path / f"target.{fmt}"
                completed, events = self.run_cli(
                    self.source, "--format", fmt, "--max-size", "5MB", "--preset", "balanced", "--output", output
                )
                result = self.assert_complete(completed, events)
                produced = Path(result["path"])
                self.assertTrue(produced.is_file())
                self.assertLessEqual(produced.stat().st_size, 5_000_000)
                self.assertEqual(result["bytes"], produced.stat().st_size)
                streams = ffprobe_json(produced)["streams"]
                self.assertTrue(any(s["codec_type"] == "video" for s in streams))
                self.assertTrue(any(s["codec_type"] == "audio" for s in streams))

    def test_video_outputs_are_8bit_420_for_any_source(self) -> None:
        # Screen recordings (4:4:4) and phone HDR clips (10-bit) must not turn
        # into High 4:4:4 / High 10 H.264 or VP9 profile 1/2: browsers and
        # chat apps cannot play those, which defeats "ready to share".
        for pix_fmt in ("yuv444p", "yuv420p10le"):
            source = self.work_path / f"source-{pix_fmt}.mkv"
            subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                            "-i", "testsrc2=size=320x180:rate=15", "-t", "2",
                            "-c:v", "libx264", "-pix_fmt", pix_fmt, str(source)],
                           check=True, capture_output=True)
            for fmt in ("mp4", "webm", "mkv", "mov"):
                for mode in (("--max-size", "2MB"), ("--preset", "balanced")):
                    with self.subTest(source=pix_fmt, format=fmt, mode=mode[0]):
                        output = self.work_path / f"out-{pix_fmt}-{mode[0][2:]}.{fmt}"
                        completed, events = self.run_cli(source, "--format", fmt, *mode, "--output", output)
                        produced = Path(self.assert_complete(completed, events)["path"])
                        video = next(s for s in ffprobe_json(produced)["streams"] if s["codec_type"] == "video")
                        self.assertEqual(video["pix_fmt"], "yuv420p")

    def test_hdr_sources_are_tone_mapped_to_sdr(self) -> None:
        # Phone clips are HLG (iPhone) or PQ (HDR10). Without tone mapping
        # the 8-bit result looks washed out wherever tags are ignored.
        filters = subprocess.run([FFMPEG, "-hide_banner", "-filters"], capture_output=True, text=True).stdout
        if " zscale " not in filters or " tonemap " not in filters:
            self.skipTest("this FFmpeg has no zscale/tonemap")
        for transfer in ("arib-std-b67", "smpte2084"):
            source = self.work_path / f"hdr-{transfer}.mkv"
            subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                            "-i", "testsrc2=size=320x180:rate=15", "-t", "2", "-vf",
                            "zscale=tin=bt709:min=bt709:pin=bt709:rin=tv:t=linear:p=bt709:m=gbr:npl=100,"
                            "format=gbrpf32le,zscale=p=bt2020:t=linear:m=gbr,"
                            f"zscale=t={transfer}:m=bt2020nc:p=bt2020:r=tv:npl=100,format=yuv420p10le",
                            "-c:v", "libx264", "-color_trc", transfer, "-color_primaries", "bt2020",
                            "-colorspace", "bt2020nc", str(source)], check=True, capture_output=True)
            probe = self.run_cli("--probe", source)[1]
            self.assertEqual(probe[-1].get("transfer"), transfer)
            for fmt, mode in (("mp4", ("--max-size", "2MB")), ("webm", ("--preset", "balanced")),
                              ("gif", ("--max-size", "2MB")), ("jpg", ("--max-size", "200KB"))):
                with self.subTest(transfer=transfer, format=fmt):
                    output = self.work_path / f"sdr-{transfer}.{fmt}"
                    completed, events = self.run_cli(source, "--format", fmt, *mode, "--output", output)
                    produced = Path(self.assert_complete(completed, events)["path"])
                    video = next(s for s in ffprobe_json(produced)["streams"] if s["codec_type"] == "video")
                    self.assertNotIn(video.get("color_transfer"), ("arib-std-b67", "smpte2084"))
                    if fmt in ("mp4", "webm"):
                        self.assertEqual(video.get("color_transfer"), "bt709")
                        self.assertEqual(video.get("color_primaries"), "bt709")

    def test_sigterm_cancels_job_without_orphan_encoder_or_temp_files(self) -> None:
        source = self.work_path / "long-source.mp4"
        self._make_video(source, duration=30, size="640x360")
        output = self.work_path / "cancelled.gif"
        temp_root = self.work_path / "owned-tmp"
        temp_root.mkdir()
        environment = os.environ.copy()
        environment["TMPDIR"] = str(temp_root)
        process = subprocess.Popen(
            [str(CLI), str(source), "--format", "gif", "--max-size", "5MB", "--preset", "high", "--output", str(output)],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.addCleanup(self._terminate_process_group, process)
        started_events = self._wait_for_cancellable_work(process, source, temp_root)
        self.assertIsNone(process.poll(), "converter exited before it could be cancelled")
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=20)
        events = started_events + [json.loads(line) for line in stdout.splitlines()]
        self.assertFalse(any(event.get("event") == "complete" for event in events), stdout)
        self.assertTrue(any(event.get("event") in {"cancelled", "error"} for event in events), stdout + stderr)
        self.assertFalse(output.exists(), "cancelled work must not publish an incomplete output")
        self.assertFalse(list(self.work_path.glob(".omaconvert-*")), "cancelled work left staging files")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(temp_root.rglob("*")):
            time.sleep(0.1)
        self.assertFalse(any(temp_root.rglob("*")), "test-owned temporary files were not cleaned")
        process_listing = subprocess.run(
            ["ps", "-eo", "args="], text=True, capture_output=True, check=True
        ).stdout
        self.assertNotIn(str(source), process_listing, "encoder for cancelled job remains running")
        self.assertNotIn(str(temp_root), process_listing, "cancelled job left a child using its TMPDIR")

    @staticmethod
    def _terminate_process_group(process: subprocess.Popen[str]) -> None:
        """Avoid leaking a converter or its children if an assertion aborts a test."""
        if process.poll() is not None:
            return
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=5)

    def _wait_for_cancellable_work(
        self, process: subprocess.Popen[str], source: Path, temp_root: Path
    ) -> list[dict]:
        """Wait for an observed active stage or child process, never a fixed delay."""
        assert process.stdout is not None
        deadline = time.monotonic() + 15
        events: list[dict] = []
        active_events = {"analyzing", "encoding", "optimizing"}
        while time.monotonic() < deadline:
            if process.poll() is not None:
                break
            ready, _, _ = select.select([process.stdout], [], [], 0.2)
            if ready:
                line = process.stdout.readline()
                if line:
                    event = json.loads(line)
                    events.append(event)
                    if event.get("event") in active_events:
                        return events
            listing = subprocess.run(
                ["ps", "-eo", "args="], text=True, capture_output=True, check=True
            ).stdout
            if any(line.split(maxsplit=1)[0].split("/")[-1] in {"ffmpeg", "ffprobe", "gifsicle"}
                   and (str(source) in line or str(temp_root) in line)
                   for line in listing.splitlines() if line.strip()):
                return events
        self.fail("converter never reached an observable active stage or spawned a child within 15 seconds")


if __name__ == "__main__":
    unittest.main()
