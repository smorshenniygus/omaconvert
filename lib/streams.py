"""Byte budgets applied before text decoding or JSON allocation."""
from .errors import ProcessFailed

class OutputLimitExceeded(ProcessFailed):
    reason = 'output-limit'
    def __init__(self):
        super().__init__('The media tool produced too much output and was stopped.')


def read_bounded(stream, limit):
    result = bytearray()
    while True:
        chunk = stream.read(min(4096, limit + 1 - len(result)))
        if not chunk:
            return bytes(result)
        result.extend(chunk)
        if len(result) > limit:
            raise OutputLimitExceeded()


def iter_bounded_lines(stream, line_limit):
    while True:
        line = stream.readline(line_limit + 1)
        if not line:
            return
        if len(line) > line_limit:
            raise OutputLimitExceeded()
        yield line
