# Worker protocol and limits

The public CLI still emits JSON lines. A private worker runs the complete Python/media pipeline under verified user cgroup v2 limits. The controller validates and bounds every worker line before forwarding it to Quickshell.

- A UTF-8 event including its newline is at most 65,536 bytes. Tool captures are at most 1 MiB; progress lines are at most 16 KiB; diagnostic tails are bounded.
- Existing terminal names remain `complete`, `batch-complete`, `error`, `cancelled`. An error may add `reason`: `protection-unavailable`, `memory-limit`, `output-limit`, `timeout`, or `worker-failed`. SIGKILL alone is not memory-limit evidence.
- Ordinary batch summaries retain `paths`. A summary too large for one event is preceded by ordered `batch-results` events containing `offset` and `paths`. Its final `batch-complete` has `resultsChunked: true`; consumers accumulate the chunks by offset. Item events retain their original `index`.
- `queued` means another conversion owns the per-user conversion slot; the request remains cancellable.
- Probe and preview have a 120-second absolute deadline, including admission. New preview generations discard stale completions. Qt only loads generated PNG previews bounded to 320 pixels per side and 1 MiB.

No worker starts decoding if systemd/cgroup protection cannot be verified. Help, version and dependency checking remain available. The protection limits resource consumption; it is not a filesystem or network sandbox.
