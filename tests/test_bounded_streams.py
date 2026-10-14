import io
import unittest

class StreamTests(unittest.TestCase):
    def test_capture_rejects_over_limit(self):
        from lib.streams import read_bounded, OutputLimitExceeded
        with self.assertRaises(OutputLimitExceeded):
            read_bounded(io.BytesIO(b'x'*17), 16)
        self.assertEqual(read_bounded(io.BytesIO(b'a'*16), 16), b'a'*16)

    def test_line_without_newline_rejected(self):
        from lib.streams import iter_bounded_lines, OutputLimitExceeded
        with self.assertRaises(OutputLimitExceeded):
            list(iter_bounded_lines(io.BytesIO(b'x'*17), 16))
        self.assertEqual(list(iter_bounded_lines(io.BytesIO('я\na'.encode()), 16)), ['я\n'.encode(), b'a'])
