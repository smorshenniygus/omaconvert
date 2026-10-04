import json
import sys


class EventSink:
    def __init__(self, stream=None):
        self.stream = stream or sys.stdout

    def emit(self, event, **fields):
        payload = {"event": event, **fields}
        self.stream.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.stream.flush()

