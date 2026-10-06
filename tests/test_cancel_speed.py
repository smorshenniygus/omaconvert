"""Cancelling must not wait for FFmpeg to finish a heavy frame: SIGTERM
lets it complete the current frame (seconds for a large PNG at maximum
compression), and the output is discarded anyway, so the group is killed
shortly after."""
import sys
import threading
import time
import unittest

from lib.errors import Cancelled, OmaConvertError
from lib.events import EventSink
from lib.process import ProcessRunner

STUBBORN = [sys.executable, "-c",
            "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"]


class CancelSpeedTests(unittest.TestCase):
    def test_cancel_kills_a_tool_that_ignores_sigterm_quickly(self):
        runner = ProcessRunner(EventSink())
        outcome = {}

        def run():
            try:
                runner.capture(STUBBORN, "stub failed")
            except (Cancelled, OmaConvertError) as exc:
                outcome["error"] = exc

        worker = threading.Thread(target=run)
        worker.start()
        time.sleep(0.4)
        started = time.monotonic()
        runner.cancel()
        worker.join(10)
        self.assertFalse(worker.is_alive())
        self.assertLess(time.monotonic() - started, 1.5)


if __name__ == "__main__":
    unittest.main()
