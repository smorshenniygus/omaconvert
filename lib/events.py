import json
import sys
import threading
from .streams import OutputLimitExceeded


class EventSink:
    def __init__(self, stream=None):
        self.stream = stream or sys.stdout
        self._lock = threading.Lock()

    def emit(self, event, **fields):
        payload = {"event": event, **fields}
        line = json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n"
        if len(line.encode("utf-8")) > 65536:
            if event == "batch-complete" and "paths" in fields:
                paths = fields.pop("paths")
                chunk = []
                offset = 0
                for path in paths:
                    candidate = {"event": "batch-results", "offset": offset, "paths": chunk + [path]}
                    if len((json.dumps(candidate, ensure_ascii=False) + "\n").encode()) > 65536:
                        if not chunk: raise OutputLimitExceeded()
                        self.emit("batch-results", offset=offset, paths=chunk)
                        offset += len(chunk)
                        chunk = []
                    chunk.append(path)
                if chunk: self.emit("batch-results", offset=offset, paths=chunk)
                self.emit(event, resultsChunked=True, **fields)
                return
            raise OutputLimitExceeded()
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

