"""The panel runs inside the shared shell for the whole session, so it never
reads a file itself: no FileView or XMLHttpRequest. Omarchy's recording
marker, the only outside file it watches, is checked and read by `find` and
`head` in their own processes (services/RecordingWatch.qml,
tests/qml/RecordingHarness.qml), and no other shared /tmp path is used."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
INTERFACE = [ROOT / "OmaConvert.qml", *ROOT.glob("components/**/*.qml"), *ROOT.glob("services/*.qml"),
             *ROOT.glob("services/*.js")]


class ShellReadTests(unittest.TestCase):
    def lines(self, pattern):
        return [f"{path.relative_to(ROOT)}:{number}" for path in INTERFACE
                for number, line in enumerate(path.read_text().splitlines(), 1)
                if re.search(pattern, line) and not line.lstrip().startswith("//")]

    def test_no_in_process_file_reads(self):
        self.assertEqual(self.lines(r"\bFileView\b|XMLHttpRequest"), [])

    def test_shared_tmp_only_for_the_legacy_recording_marker(self):
        self.assertEqual(self.lines(r"/tmp\b"), [line for line in self.lines(r"/tmp/omarchy-screenrecord-filename")
                                                 if line.startswith("services/RecordingWatch.qml")])


if __name__ == "__main__":
    unittest.main()
