import json
import sys
import time
import threading
from .streams import OutputLimitExceeded


class EventSink:
    def __init__(self, stream=None):
        self.stream = stream or sys.stdout
        self._lock = threading.Lock()
        self._progress = {}

    def emit(self, event, **fields):
        if "progress" in fields and event not in ("complete", "batch-complete", "error", "cancelled"):
            key = (event, fields.get("index"))
            now = time.monotonic()
            value = fields["progress"]
            with self._lock:
                previous = self._progress.get(key)
                if previous and now - previous[0] < .1 and not (value == 1 and previous[1] != 1):
                    return
                self._progress[key] = (now, value)
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

