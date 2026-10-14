# Contained workers validation

## Scope and integration

Implemented in `feat/contained-workers`, isolated under `.worktrees/contained-workers`.
Remote fetched on 2026-10-14: `origin/main` was `f16eae2` (1.3.5). Local refactors were applied as `b5fdb6b`, `9ff472b`, `cc5ac4e`, retaining release protections. Main implementation/review fixes: `4719145`, `dd14bdb`, `d4a7cf5`, `bfce225`.

No installed plugin replacement, desktop-shell restart, push, release, or marketplace comment was performed. Filesystem/network sandboxing and arbitrary decoder code-execution containment are outside this iteration.

## Verification environment and interpretation

Live cgroup tests require the real user systemd manager. The initial sandbox baseline (247 tests, 81 failures, 68 errors) was invalid because that sandbox denied the user bus. Subsequent live runs were explicitly authorized outside it. QML tests retain the actual runtime directory but isolate configuration/cache. An integration failure in missing-tool diagnostics was reproduced and fixed by ordering wrappers as scope -> exec-helper -> tool.

`memoryPeakSampled` is an observed cgroup peak, not a promise to capture the final peak before the cgroup disappears. OOM attribution also checks systemd's `Result`; arbitrary SIGKILL is not labeled OOM.

## Final security run

Command: `PYTHONDONTWRITEBYTECODE=1 bash scripts/check-security.sh`.

All 14 tests executed and passed: four live cgroup tests, seven controller/lifecycle tests and three hostile-media/QML tests. Enforcement is established using a synthetic allocator before generating or decoding the PNG. No unrestricted bomb decoder baseline is run.

- Fixture: 1,052,631 bytes; 1,073,741,824 bytes of expanded metadata.
- SHA256: `00d5be9efdc13e8738cd6308bbdfa64d4b0bce999fcf8224f7f2a6be8f6dcf3f`.
- Worker limit: 268,435,456 bytes, swap disabled, external deadline 30 seconds.
- Preview: controlled `memory-limit` error, exit 2; 0.427 seconds; sampled peak 268,435,456 bytes; `oomKill=3`, systemd `result=oom-kill`.
- Probe: successful bounded metadata response, exit 0; 0.157 seconds; sampled peak 30,564,352 bytes; no OOM.
- Isolated QML: hostile selection followed by a normal image recovered successfully; 13 responsiveness timer ticks.
- Fixtures were temporary and removed by the suite. Only the bounded generator and tests are committed.

Checks cover a shared aggregate budget across two scopes, Python/child ancestry, whole-job OOM, inspection deadline, excessive stdout, external SIGKILL classification, controller death, mixed-flag admission, and cancellable second-conversion queueing. Separate regressions cover grandchildren and pipes retained after their leader exits.

## Full regression gate

Before the final status fallback: 270 Python tests and 39 QML tests passed; plugin validation and qmllint passed. Three existing `block-scope-var-declaration` warnings remain (OmaConvert.qml twice, TrimBar.qml once).

The final status fallback was reproduced RED with a deliberately unavailable user bus, then passed all three worker tests. It preserves desktop settings with `capabilities_error` and never queries media tools outside protection. Final full run after that fix: **271 Python tests passed in 132.413 seconds; 39 QML tests passed with zero skipped/failed; plugin validation and qmllint passed**, with the same three existing warnings. Command: `PYTHONDONTWRITEBYTECODE=1 bash scripts/check.sh`. `git diff --check` also passed.

## Media and visual acceptance

Earlier in this implementation session, the full isolated offscreen OmaConvert window was rendered and inspected: source thumbnail, input field and recipes were legible without a layout regression. Keyboard, trim, preview-position, cancellation and service lifecycle behavior are exercised by automated QML/integration tests. These checks are not a physical-display or manual desktop installation test.

A generated 1-second 3840x2160, 10 fps H.264 testsrc2 clip was compared between integrated baseline `178b71b` and implementation `d4a7cf5`. Its 3,272,271-byte source SHA256 was `fcbba985b747d619de38f92fd3584dd67813213355470e36c47df8494afd24d2`.

| Output | Baseline / worker seconds | Baseline / worker max process RSS KiB | Bytes | Dimensions |
| --- | --- | --- | --- | --- |
| MP4 balanced | 0.415 / 0.469 | 371264 / 371012 | 101835 | 1280x720 |
| WebM target 1 MB | 4.133 / 4.178 | 1713596 / 1713572 | 906220 | 2560x1440 |
| GIF target 1 MB | 4.862 / 4.864 | 458724 / 458620 | 965134 | 1600x900 |

Each pair was byte-identical and decoded successfully. Output SHA256 values, respectively:

- `c0c46b1187c6e9c44cf1b34858a8993ce5e4c774b0cd4cb6677c4958a3d93459`
- `3f562ce7712bd91845776b2aaca30bd5f1a4d0b3fc3f257fa1551143bd58998c`
- `db845be15c7b51ae9da458e6f6356f39029844bf1abb0651e067b76cdfee266e`

This is one short synthetic sample, measured alongside other tests, before the final lifetime guard changes. RSS is per-process, not aggregate cgroup memory. It is not a performance guarantee for long real footage or a benchmark of the final guard overhead. Prior temporary screenshots/measurement files were unavailable after session resumption; these are recorded earlier observations. Fresh full regression/security logs were collected again after resumption. Normal image transparency, portrait orientation, HDR-to-SDR, GIF/video decoding, size targets and batches are covered by the regression suite, rather than an exhaustive baseline quality benchmark.

## Independent review and dispositions

One read-only GPT-6 Astra / High reviewer ran while the lead performed media/UI acceptance. All five substantive findings were addressed:

1. Mixed utility/media flags could bypass admission: one shared dispatch precedence now governs both entrypoints; regression reproduced RED then GREEN.
2. Timeout watchdog ended when the leader exited while a descendant retained stdout: watchdog now covers stream drainage and kills remaining group members; RED then GREEN.
3. Grandchildren could survive controller death: independent bounded guard kills/stops the job scope on controller-channel EOF; live RED then GREEN.
4. Whole-job OOM depended on host defaults: explicit `OOMPolicy=kill`, verified `memory.oom.group=1`, and immediate controller OOM reaction. Host default test already passed; explicit policy verified after the fix.
5. Preview cleanup could remove another active temporary file and UI instances shared slots: cleanup now follows ownership registry; each UI has a private session directory; stale dead-session cleanup is tested. RED then GREEN.

No minor findings were deferred. Final plan audit also restored desktop-only status when protection is unavailable.

## Implementation rulings and costs

1. Worker entrypoint and bounded relay were introduced together before public dispatch switched: extra integration work, avoids an intermediate unbounded boundary.
2. Peak reporting is explicitly sampled, supplemented by systemd OOM evidence: exact final peaks can be unavailable.
3. Real QML integration uses the real runtime directory: tests need a user manager; settings/cache remain isolated.
4. Inspection is serialized across user instances: simultaneous windows may briefly queue.
5. An independent bounded guard is outside the media cgroup: one additional small Python process/startup per job; 128 MiB address-space and 5-second CPU limits, no media parsing.
6. Filesystem/network isolation is deferred by the approved scope: resource containment does not prevent arbitrary decoder exploitation or establish marketplace approval.

## Execution report

Implementation/integration/verification remained with the lead. One subagent, GPT-6 Astra with High reasoning, performed read-only final review in parallel with acceptance work. No model escalation. The lead's exact runtime model/effort and token/credit/allowance metrics are not exposed here: usage unavailable.
