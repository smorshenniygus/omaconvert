"""Every media tool runs under a memory cap: reading a chosen file (probe,
preview) gets a small one, encoders a share of the machine. A tool that goes
over is stopped by the kernel and reported as such, instead of eating the
machine's memory."""
import os
import sys
import unittest
from unittest import mock

from lib import preview as preview_module, probe as probe_module, process
from lib.errors import ProcessFailed
from lib.process import INSPECT_MEMORY, ProcessRunner, confined, encode_memory


class Sink:
    def emit(self, *_args, **_fields):
        pass


GREEDY = [sys.executable, "-c", "x = bytearray(700 * 1024 * 1024); x[::4096] = b'1' * len(x[::4096])"]


class MemoryCapTests(unittest.TestCase):
    def test_every_launch_is_confined(self):
        args = confined(["ffprobe", "-version"], INSPECT_MEMORY)
        self.assertEqual(args[-2:], ["ffprobe", "-version"])
        self.assertTrue(os.path.basename(args[0]) == "systemd-run", args)
        self.assertGreaterEqual(encode_memory(), 2 * 1024 ** 3)

    def test_arguments_reach_the_tool_unchanged(self):
        name = "Видео $HOME $(echo x) 100% ${PATH}.mp4"
        out = ProcessRunner(Sink()).capture([sys.executable, "-c", "import sys; print(sys.argv[1])", name], "echo")
        self.assertEqual(out.strip(), name)

    @unittest.skipUnless(process._scope_available(), "user systemd manager required")
    def test_a_killed_tool_is_not_falsely_attributed_without_scope_evidence(self):
        runner = ProcessRunner(Sink())
        with self.assertRaises(ProcessFailed) as caught:
            runner.capture(GREEDY, "Could not read the input media.", timeout=30, memory=200 * 1024 ** 2)
        self.assertNotIn("needed more", caught.exception.message)

    def test_reading_a_file_uses_the_small_cap(self):
        seen = []
        real = process.confined

        def spy(args, memory):
            seen.append((os.path.basename(args[0]), memory))
            return real(args, memory)

        here = os.path.dirname(os.path.abspath(__file__))
        image = os.path.join(here, "..", "assets", "kv.jpg")
        with mock.patch.object(process, "confined", spy):
            info = probe_module.probe_media(image, ProcessRunner(Sink()))
            out = os.path.join(self._tmp(), "p.png")
            preview_module.generate_preview(ProcessRunner(Sink()), image, out, info=info)
        self.assertTrue(seen and all(memory == INSPECT_MEMORY for _, memory in seen), seen)

    def _tmp(self):
        import tempfile
        d = tempfile.TemporaryDirectory(prefix="omaconvert-mem-")
        self.addCleanup(d.cleanup)
        return d.name


if __name__ == "__main__":
    unittest.main()
