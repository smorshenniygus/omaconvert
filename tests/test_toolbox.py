"""What FFmpeg can do is asked once per job or batch, before any worker
starts, through the job's runner: cancelling stops the question, workers
receive the immutable answer, and writing the answer down never touches the
process-wide umask."""
import dataclasses
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from lib import color, formats, preview
from lib.backend import convert, convert_batch
from lib.errors import Cancelled, OmaConvertError
from lib.probe import MediaInfo
from lib.process import ProcessRunner

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"

TABLES = """
case "$2" in
  -encoders) printf " V..... libx264 x\\n A..... aac x\\n V..... png x\\n V..... mjpeg x\\n" ;;
  -muxers) printf "  E mp4 x\\n  E image2 x\\n" ;;
  -filters) printf " ... scale V->V x\\n" ;;
esac
"""


class NullSink:
    def emit(self, *_args, **_fields):
        pass


def alive(pid):
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return False
    return state not in ("Z", "X")


def wait_for(predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


class StubFfmpeg(unittest.TestCase):
    """A temporary bin folder with a scripted ffmpeg that logs every call."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-toolbox-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "ffmpeg.log"
        self.cache_home = self.root / "cache"
        patcher = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.cache_home),
                                               "XDG_CONFIG_HOME": str(self.root / "config"),
                                               "XDG_DATA_HOME": str(self.root / "data"),
                                               "PATH": f"{self.bin}:{os.environ['PATH']}"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def script(self, name, body):
        path = self.bin / name
        path.write_text(f"#!/bin/sh\n{body}")
        path.chmod(0o755)
        return path

    def stub(self, body=TABLES):
        return self.script("ffmpeg", f'echo "$*" >> {self.log}\n{body}')

    def calls(self, flag):
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        return [line for line in lines if flag in line.split()]

    def runner(self):
        return ProcessRunner(NullSink())


class DiscoveryTests(StubFfmpeg):
    def test_asks_each_table_once_and_returns_an_immutable_toolbox(self):
        stub = self.stub()
        tools = formats.toolbox(self.runner(), str(stub))
        self.assertEqual([len(self.calls(flag)) for flag in ("-encoders", "-muxers", "-filters")], [1, 1, 1])
        self.assertIn("libx264", tools.encoders)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            tools.encoders = frozenset()
        self.assertTrue(all(isinstance(table, frozenset) for table in (tools.encoders, tools.muxers, tools.filters)))

    def test_cancelling_during_discovery_stops_the_running_tool_and_asks_no_more(self):
        pid_file = self.root / "pid"
        self.stub(f'case "$2" in -encoders) echo $$ > {pid_file}; exec sleep 30 ;; esac\n' + TABLES)
        runner = self.runner()
        outcome = []

        def ask():
            try:
                formats.toolbox(runner)
            except Cancelled as exc:
                outcome.append(exc)

        worker = threading.Thread(target=ask)
        worker.start()
        self.assertTrue(wait_for(lambda: pid_file.exists() and pid_file.read_text().strip()))
        sleeper = int(pid_file.read_text())
        self.assertTrue(alive(sleeper))
        started = time.monotonic()
        runner.cancel()
        worker.join(10)
        self.assertFalse(worker.is_alive())
        self.assertLess(time.monotonic() - started, 2.0)
        self.assertEqual(len(outcome), 1, "cancelling must end the question with Cancelled")
        self.assertTrue(wait_for(lambda: not alive(sleeper)), "the discovery process kept running")
        self.assertEqual(self.calls("-muxers") + self.calls("-filters"), [])
        self.assertFalse((self.cache_home / "omaconvert" / "toolbox.json").exists())

    def test_a_failing_ffmpeg_is_a_controlled_error_and_is_not_cached(self):
        self.stub('case "$2" in -encoders) echo boom >&2; exit 1 ;; esac\n' + TABLES)
        with self.assertRaises(OmaConvertError) as caught:
            formats.toolbox(self.runner())
        self.assertNotIsInstance(caught.exception, Cancelled)
        self.assertEqual(caught.exception.message, "Could not ask FFmpeg which formats it supports.")
        self.assertEqual(caught.exception.details, "boom")
        self.assertFalse((self.cache_home / "omaconvert" / "toolbox.json").exists())

    def test_no_ffmpeg_means_no_toolbox(self):
        with mock.patch("lib.formats.shutil.which", return_value=None):
            self.assertIsNone(formats.toolbox(self.runner()))


class CacheWriteTests(StubFfmpeg):
    def test_writing_the_cache_never_changes_the_process_umask(self):
        stub = self.stub()
        previous = os.umask(0o000)
        self.addCleanup(os.umask, previous)
        with mock.patch("os.umask", side_effect=AssertionError("the process umask was touched")):
            formats.toolbox(self.runner(), str(stub))

    def test_cache_is_private_under_a_permissive_umask_even_with_missing_parents(self):
        stub = self.stub()
        deep = self.root / "a" / "b" / "cache"
        previous = os.umask(0o000)
        self.addCleanup(os.umask, previous)
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(deep)}):
            formats.toolbox(self.runner(), str(stub))
        cache = deep / "omaconvert" / "toolbox.json"
        self.assertTrue(cache.is_file())
        self.assertEqual(stat.S_IMODE(cache.stat().st_mode), 0o600)
        for folder in (deep / "omaconvert", deep, deep.parent, deep.parent.parent):
            self.assertEqual(stat.S_IMODE(folder.stat().st_mode), 0o700, folder)

    def test_an_unwritable_cache_is_not_fatal(self):
        stub = self.stub()
        blocker = self.root / "not-a-folder"
        blocker.write_text("a file where the cache folder should be")
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(blocker)}):
            tools = formats.toolbox(self.runner(), str(stub))
        self.assertIn("libx264", tools.encoders)
        locked = self.root / "locked"
        locked.mkdir()
        locked.chmod(0o500)
        self.addCleanup(locked.chmod, 0o700)
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(locked)}):
            self.assertIn("libx264", formats.toolbox(self.runner(), str(stub)).encoders)

    def test_a_damaged_cache_is_asked_again(self):
        stub = self.stub()
        cache = self.cache_home / "omaconvert" / "toolbox.json"
        formats.toolbox(self.runner(), str(stub))
        cache.write_text(json.dumps({key: {"encoders": 5} for key in json.loads(cache.read_text())}))
        self.assertIn("libx264", formats.toolbox(self.runner(), str(stub)).encoders)
        self.assertEqual(len(self.calls("-encoders")), 2)


class RunnerTests(StubFfmpeg):
    def test_runners_of_a_job_share_one_answer_and_one_cancellation(self):
        self.stub()
        original = self.runner()
        worker = original.for_sink(NullSink())
        self.assertIsNone(original.toolbox)
        self.assertIsNone(worker.toolbox)
        tools = original.prepare_toolbox()
        self.assertIsInstance(tools, formats.Toolbox)
        self.assertIs(original.toolbox, tools)
        self.assertIs(worker.toolbox, tools, "a runner made before the question still sees the answer")
        self.assertIs(worker.prepare_toolbox(), tools)
        self.assertEqual(len(self.calls("-encoders")), 1)
        worker.cancel()
        self.assertTrue(original.cancelled)

    def test_threads_asking_together_ask_ffmpeg_once(self):
        self.stub('sleep 0.2\n' + TABLES)
        runner = self.runner()
        answers, start = [], threading.Barrier(8)

        def ask():
            start.wait()
            answers.append(runner.for_sink(NullSink()).prepare_toolbox())

        threads = [threading.Thread(target=ask) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(30)
        self.assertEqual(len(answers), 8)
        self.assertTrue(all(answer is answers[0] for answer in answers))
        self.assertEqual(len(self.calls("-encoders")), 1)

    def test_a_cancelled_question_leaves_nothing_behind(self):
        self.stub()
        runner = self.runner()
        runner.cancel()
        with self.assertRaises(Cancelled):
            runner.prepare_toolbox()
        self.assertIsNone(runner.toolbox)
        self.assertEqual(self.calls("-encoders"), [])


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
class BatchTests(StubFfmpeg):
    def setUp(self):
        super().setUp()
        self.images = []
        for index, color_name in enumerate(("red", "green", "blue", "white")):
            path = self.root / f"image-{index}.png"
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                            "-i", f"testsrc2=s=320x180,drawbox=c={color_name}@0.3:t=fill", "-frames:v", "1",
                            str(path)], check=True)
            self.images.append(path)
        real = shutil.which("ffmpeg", path=os.environ["PATH"].replace(f"{self.bin}:", "", 1))
        self.script("ffmpeg", f'echo "$*" >> {self.log}\nexec {real} "$@"\n')
        self.log.write_text("")

    def convert_batch(self, runner, jobs=3):
        return convert_batch(runner, [str(path) for path in self.images], "jpg", 30_000, "balanced",
                             "balanced", output_dir=str(self.root), jobs=jobs)

    def test_a_cold_cache_batch_asks_ffmpeg_once_for_all_workers(self):
        self.assertFalse(self.cache_home.exists())
        summary = self.convert_batch(self.runner())
        self.assertEqual(summary["done"], len(self.images))
        self.assertEqual([len(self.calls(flag)) for flag in ("-encoders", "-muxers", "-filters")], [1, 1, 1])

    def test_workers_of_a_prepared_batch_never_ask_again(self):
        runner = self.runner()
        runner.prepare_toolbox()
        self.log.write_text("")
        with mock.patch.object(formats, "toolbox", side_effect=AssertionError("a worker asked FFmpeg")):
            summary = self.convert_batch(runner)
        self.assertEqual(summary["done"], len(self.images))
        self.assertEqual(self.calls("-encoders") + self.calls("-muxers") + self.calls("-filters"), [])

    def test_a_single_conversion_asks_once_and_before_any_analysis(self):
        convert(self.runner(), self.images[0], "jpg", None, 30_000, "balanced", "balanced",
                output_dir=str(self.root))
        lines = self.log.read_text().splitlines()
        self.assertEqual([len(self.calls(flag)) for flag in ("-encoders", "-muxers", "-filters")], [1, 1, 1])
        self.assertTrue(all("-encoders" in line or "-muxers" in line or "-filters" in line
                            for line in lines[:3]), lines[:3])


class MissingEncoderTests(StubFfmpeg):
    def test_a_missing_encoder_is_reported_before_the_file_is_analysed(self):
        self.stub()  # no libwebp
        probed = self.root / "ffprobe.log"
        self.script("ffprobe", f'echo "$*" >> {probed}\nexit 1\n')
        source = self.root / "photo.png"
        source.write_bytes(b"not decoded")
        with self.assertRaises(OmaConvertError) as caught:
            convert(self.runner(), source, "webp", None, 30_000, "balanced", "balanced")
        self.assertIn("libwebp", caught.exception.message)
        self.assertFalse(probed.exists(), "FFmpeg's tools were used before the missing encoder was reported")
        self.assertEqual(self.calls("-i"), [])

    def test_a_batch_reports_it_for_each_file_without_analysing_any(self):
        self.stub()
        probed = self.root / "ffprobe.log"
        self.script("ffprobe", f'echo "$*" >> {probed}\nexit 1\n')
        sources = []
        for index in range(3):
            sources.append(self.root / f"photo-{index}.png")
            sources[-1].write_bytes(b"not decoded")
        sink = mock.Mock()
        with self.assertRaises(OmaConvertError):  # none of the files could be converted
            convert_batch(ProcessRunner(sink), [str(path) for path in sources], "webp", 30_000, "balanced",
                          "balanced", jobs=3)
        errors = [call for call in sink.emit.call_args_list if call.args[0] == "item-error"]
        self.assertEqual(len(errors), 3)
        self.assertTrue(all("libwebp" in call.kwargs["message"] for call in errors))
        self.assertFalse(probed.exists())
        self.assertEqual([len(self.calls(flag)) for flag in ("-encoders", "-muxers", "-filters")], [1, 1, 1])


class BatchFailureTests(StubFfmpeg):
    def test_a_batch_whose_ffmpeg_cannot_be_asked_fails_once_before_any_file_starts(self):
        self.stub('echo boom >&2\nexit 1\n')
        sources = []
        for index in range(3):
            sources.append(self.root / f"photo-{index}.png")
            sources[-1].write_bytes(b"not decoded")
        sink = mock.Mock()
        with self.assertRaises(OmaConvertError) as caught:
            convert_batch(ProcessRunner(sink), [str(path) for path in sources], "jpg", 30_000, "balanced",
                          "balanced", jobs=3)
        self.assertEqual(caught.exception.message, "Could not ask FFmpeg which formats it supports.")
        self.assertEqual(sink.emit.call_args_list, [], "no file may be announced or reported")
        self.assertEqual(len(self.calls("-encoders")), 1)


class CliCancellationTests(StubFfmpeg):
    def sleeping_ffmpeg(self):
        pid_file = self.root / "pid"
        self.stub(f'case "$2" in -encoders) echo $$ > {pid_file}; exec sleep 30 ;; esac\n' + TABLES)
        self.script("ffprobe", "exit 1\n")
        return pid_file

    def test_sigterm_while_ffmpeg_is_being_asked_ends_the_command_promptly(self):
        source = self.root / "clip.mp4"
        source.write_bytes(b"x")
        for args in (["--capabilities"], ["--status"], [str(source), "--format", "mp4"]):
            with self.subTest(args=args):
                pid_file = self.sleeping_ffmpeg()
                pid_file.unlink(missing_ok=True)
                process = subprocess.Popen([str(CLI), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, start_new_session=True)
                self.addCleanup(lambda p=process: (p.kill(), p.wait(), p.stdout.close(), p.stderr.close()))
                self.assertTrue(wait_for(lambda: pid_file.exists() and pid_file.read_text().strip(), 15))
                sleeper = int(pid_file.read_text())
                process.send_signal(signal.SIGTERM)
                started = time.monotonic()
                stdout, _stderr = process.communicate(timeout=10)
                self.assertLess(time.monotonic() - started, 3.0)
                self.assertEqual(process.returncode, 143)
                self.assertEqual(json.loads(stdout.splitlines()[-1])["event"], "cancelled")
                self.assertTrue(wait_for(lambda: not alive(sleeper)), "the discovery process kept running")

    def test_a_failing_ffmpeg_is_reported_by_status_and_capabilities(self):
        self.stub('echo boom >&2\nexit 1\n')
        self.script("ffprobe", "exit 0\n")
        done = subprocess.run([str(CLI), "--status"], capture_output=True, text=True, timeout=60)
        status = json.loads(done.stdout.splitlines()[-1])
        self.assertEqual(status["capabilities_error"], "boom")
        done = subprocess.run([str(CLI), "--capabilities"], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 2)
        event = json.loads(done.stdout.splitlines()[-1])
        self.assertEqual((event["event"], event["message"], event["details"]),
                         ("error", "Could not ask FFmpeg which formats it supports.", "boom"))


class ToneMappingTests(unittest.TestCase):
    HDR = MediaInfo("clip.mov", 3.0, 320, 180, 30.0, "hevc", 1000, True, transfer="arib-std-b67")
    SDR = MediaInfo("clip.mov", 3.0, 320, 180, 30.0, "h264", 1000, True)
    CAPABLE = formats.Toolbox(frozenset(), frozenset(), frozenset({"zscale", "tonemap"}))
    LACKING = formats.Toolbox(frozenset(), frozenset(), frozenset({"scale"}))

    def test_tone_mapping_follows_the_prepared_toolbox(self):
        self.assertIn("tonemap", color.sdr_filter(self.HDR, self.CAPABLE))
        self.assertEqual(color.sdr_filter(self.HDR, self.LACKING), "")
        self.assertEqual(color.sdr_filter(self.HDR, None), "")
        self.assertEqual(color.sdr_filter(self.SDR, self.CAPABLE), "")

    def test_a_preview_asks_only_for_hdr_and_only_when_nobody_has(self):
        runner = ProcessRunner(NullSink())
        with mock.patch.object(formats, "toolbox", side_effect=AssertionError("asked")):
            self.assertEqual(preview._sdr_filter(runner, self.SDR), "")
        with mock.patch.object(formats, "toolbox", return_value=self.CAPABLE) as asked:
            self.assertIn("tonemap", preview._sdr_filter(runner, self.HDR))
            self.assertIn("tonemap", preview._sdr_filter(runner, self.HDR))
        asked.assert_called_once_with(runner)

    def test_a_preview_goes_on_without_tone_mapping_when_ffmpeg_cannot_be_asked(self):
        runner = ProcessRunner(NullSink())
        with mock.patch.object(formats, "toolbox", side_effect=OmaConvertError("cannot ask")):
            self.assertEqual(preview._sdr_filter(runner, self.HDR), "")
        with mock.patch.object(formats, "toolbox", side_effect=Cancelled("cancelled")):
            with self.assertRaises(Cancelled):
                preview._sdr_filter(runner, self.HDR)


if __name__ == "__main__":
    unittest.main()
