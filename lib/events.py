import json
import sys
import threading


class EventSink:
    def __init__(self, stream=None):
        self.stream = stream or sys.stdout
        self._lock = threading.Lock()

    def emit(self, event, **fields):
        payload = {"event": event, **fields}
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
        # Files of a parallel batch report from several threads: one whole
        # line at a time.
        with self._lock:
            self.stream.write(line)
            self.stream.flush()


class ItemSink:
    """Tags every event of one batch file with its `index`."""

    def __init__(self, sink, index):
        self.sink = sink
        self.index = index

    def emit(self, event, **fields):
        fields.setdefault("index", self.index)
        self.sink.emit(event, **fields)

