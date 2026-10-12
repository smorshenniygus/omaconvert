"""The panel is loaded for the whole shell session. Every editable or
selectable Qt text item reads the clipboard each time it changes, in the
shell process, without a size or time limit; so the interface has none of
them. Typing goes through components/ui/LineEdit.qml and Ctrl+V through the
backend, which reads with bounds (tests/test_desktop.py)."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
QT_TEXT_INPUTS = re.compile(r"\b(?:\w+\.)?(TextField|TextInput|TextEdit|TextArea)\s*\{")


class ClipboardTests(unittest.TestCase):
    def test_no_qt_text_input_in_the_interface(self):
        files = [ROOT / "OmaConvert.qml", *ROOT.glob("components/**/*.qml"), *ROOT.glob("services/*.qml")]
        offenders = [f"{path.relative_to(ROOT)}:{number}" for path in files
                     for number, line in enumerate(path.read_text().splitlines(), 1)
                     if QT_TEXT_INPUTS.search(line)]
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
