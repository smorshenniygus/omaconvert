# Contained media workers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Объединить релизные защиты и локальный рефакторинг, ограничить всё дерево обработки медиа и доказать защиту реальной PNG-бомбой.

**Architecture:** Существующий CLI становится ограниченным по обмену контроллером для media worker. Worker включает Python и инструменты в пользовательскую cgroup задания; общий transient slice ограничивает сумму всех заданий пользователя. Существующие кодировщики, проверка результата и no-clobber публикация остаются внутри worker.

**Tech Stack:** Python standard library, systemd user / cgroup v2, FFmpeg, Quickshell/QML, unittest.

**Spec:** [Approved design](../specs/2026-10-14-contained-workers-design.md)

## Global Constraints

- Не менять исходники, существующие результаты, качество, клавиатуру и внешний вид. Сохранять существующие CLI и имена событий; расширения протокола согласованно поддерживать в QML.
- Реализация в отдельном worktree; не изменять чужой worktree и untracked-файлы. Не устанавливать плагин, не публиковать релиз, не писать в GitHub, не перезапускать рабочий shell.
- Без `preexec_fn`, без запуска медиа при неподтверждённой защите; systemd user + cgroup v2 memory обязательны для media work. Help/version/диагностика доступны без них.
- Общая память: `min(floor(0.6 * capacity), capacity - 1 GiB)`, где capacity — минимум RAM и конечных лимитов предков. Неположительный результат означает отказ. Нет нижнего порога, который повышает общий предел.
- Inspection: `min(2 GiB, общий предел)`, 120 секунд с момента принятия запроса; encoding stall 300 секунд с сохранением существующей настройки. `MemorySwapMax=0`.
- Захват stdout ≤1 MiB; строка progress ≤16 KiB; JSONL событие ≤64 KiB включая newline; stderr tail ≤8 KiB; превью ≤320×320 и ≤1 MiB.
- Тест бомбы: потенциально 1 GiB zTXt, worker 256 MiB, внешний deadline 30 секунд. Только после успешной живой проверки enforcement allocator-ом.
- Файловая/сетевая песочница вне этой итерации; allowlist остаётся обязательным.

## Review Focus

- Два независимых CLI и пакет: общий лимит и очередь не обходятся отдельными процессами (Task 2, 3).
- Медленный/молчащий worker и строка без newline: контроллер не зависает и не растёт без предела (Task 3, 4).
- Большой batch: ограничение JSON не ломает список результатов или соответствие индексов (Task 4).
- Гибель контроллера при старте systemd: потомки завершаются, сторонние задания не затрагиваются (Task 3, 5).
- Исправленный FFmpeg игнорирует zTXt: тест не требует OOM, но отдельно доказывает enforcement (Task 6).

## File boundaries

- `lib/confinement.py`: budget, transient slice/scope lifecycle, проверка cgroup, наблюдения OOM; без обработки медиа.
- `lib/controller.py`: запуск worker, readiness/liveness канал, bounded relay, deadline и outcome.
- `lib/streams.py`: ограниченное бинарное чтение и framing; общий для runner и relay.
- `bin/omaconvert-worker`, `lib/cli.py`: разделение public dispatch и существующей обработки задания. Внутренний entrypoint проверяет группу до чтения медиа.
- `lib/process.py`, `bin/omaconvert-exec`: supervision инструментов и parent-death, без Python preexec callbacks.
- `lib/events.py`, `services/Model.js`, `services/ConvertService.qml`: ограниченные события и совместимые batch chunks.
- `lib/probe.py`, `lib/preview.py`, `services/PreviewService.qml`, `services/PreviewSlot.qml`: ограниченные метаданные/превью и одна актуальная автоматическая операция.
- `tests/security/`, `scripts/check-security.sh`: opt-in реальные проверки, генераторы и evidence; обычный unittest не запускает бомбу.

### Task 1: Verified integrated baseline

**Files:** пересечения `lib/process.py`, `lib/preview.py`, `lib/encoders.py`; остальные файлы трёх переносимых коммитов. Evidence: `docs/validation/contained-workers.md`.

**Interfaces:** consumes local `f16eae2`, `121a6f0`, `9bcb153`, `df53836`; produces integration branch with both protection and refactor suites.

- [ ] По using-git-worktrees создать изолированный worktree; проверить remote HEAD read-only fetch, записать хеши. Если remote изменился, изучить новые коммиты до выбора базы.
- [ ] Перенести три локальных коммита по порядку, сохранив обе стороны пересечений. Перенести согласованные spec/plan отдельными документами, не весь untracked backlog.
- [ ] Выполнить `PYTHONDONTWRITEBYTECODE=1 bash scripts/check.sh`. Все проверки должны пройти; отдельно отметить baseline qmllint warnings. Исправлять только ошибки интеграции.
- [ ] Проверить отсутствие `preexec_fn`, сохранность input allowlist, memory cap, toolbox и CliCall contract. Зафиксировать интеграцию и evidence отдельным коммитом.

### Task 2: Shared budget and proven cgroup enforcement

**Files:** create `lib/confinement.py`, `tests/test_confinement.py`, `tests/security/test_cgroup.py`; modify `lib/tuning.py`.

**Interfaces:** `Budget(total_bytes: int, inspect_bytes: int)`; `effective_budget(mem_total: int, ancestor_limits: list[int]) -> Budget`; `JobScope` context manager with `start(argv: list[str], profile: str)`, `verify(pid: int)`, `stop()`, `observations() -> dict`. Observations include verified limits, memory peak when available, OOM counters and scope identity.

- [ ] Write failing tests: 8 GiB capacity yields floor(0.6×8 GiB); 2 GiB ancestor yields 1 GiB budget; 1 GiB capacity refuses. Two jobs share one parent limit; missing controller/refused properties never start the payload.
- [ ] Run `python3 -m unittest tests.test_confinement -v`; confirm failures represent missing contract.
- [ ] Implement ephemeral `omaconvert.slice` and unique job scopes with user systemd. Serialize parent creation/configuration under a private per-user flock; concurrent callers must not raise an active limit. Verify actual cgroup paths/properties before releasing worker readiness barrier. Names contain generated IDs, never user filenames. No persistent unit files.
- [ ] Implement cancellable conversion admission with a private per-user flock: initially one conversion/batch at a time across CLI instances; image parallelism remains inside that job. Automatic inspection shares the parent budget.
- [ ] Live-test two scope payloads and 256 MiB allocator enforcement; check sum accounting, swap setting, cleanup and denied controller path. Test assertions use cgroup membership/events, not only argv.
- [ ] Run unit/live tests, record evidence and commit. If systemd mode fails process lifetime requirements, resolve here before introducing media payloads.

### Task 3: Put the entire media pipeline inside the worker

**Files:** create `lib/controller.py`, `bin/omaconvert-worker`, `tests/test_worker.py`; modify `lib/cli.py`, `lib/process.py`, `bin/omaconvert-exec`.

**Interfaces:** `run_controlled(argv: list[str], profile: str, sink: EventSink) -> int`; `run_worker(argv: list[str]) -> int`. Profiles are `inspect` and `convert`; readiness and parent-liveness use a private inherited IPC channel, not an environment flag that merely claims protection.

- [ ] Write failing tests: worker Python and FFmpeg share job ancestry; direct worker entry outside verified group refuses; probe/preview/probe-all/capabilities all route through confinement; help/version/check work without it. Status capability discovery uses a bounded worker and reports unavailable protection without failing unrelated desktop status.
- [ ] Run `python3 -m unittest tests.test_worker -v` and confirm failures.
- [ ] Split CLI dispatch from media execution, preserving arguments and outcomes. Controller performs no media decoding. Retain exec-helper inside worker; readiness opens only after Task 2 verification.
- [ ] Enforce total inspection deadline including scope startup, and controller-death detection independent of systemd-run PID assumptions. Queue wait is cancellable. Worker failure does not leave controller waiting on inherited pipes forever.
- [ ] Verify `python3 -m unittest tests.test_worker tests.test_process_launch tests.test_killed_backend tests.test_cancel_speed tests.test_toolbox -v`; add live SIGKILL-at-start test and simultaneous CLI/batch test. Commit.

### Task 4: Bounded tool output and QML protocol

**Files:** create `lib/streams.py`, `tests/test_bounded_streams.py`, `tests/test_event_limits.py`; modify process/events/probe and QML Model/ConvertService/CliCall/PreviewSlot; add `docs/event-protocol.md`.

**Interfaces:** `read_bounded(stream, limit: int) -> bytes`; `iter_bounded_lines(stream, line_limit: int)` yielding bytes; limit breach raises dedicated `OutputLimitExceeded`. `EventSink.emit` retains signature and validates encoded size before writing. Controller relays only validated bounded events.

- [ ] Write tests: endless output and no-newline output terminate at byte limit; split UTF-8 chunks preserve text; stderr stays ≤8192 bytes; oversized JSON is rejected before parsing; malformed/nonfinite fields fail cleanly; oversized batch yields ordered complete results through chunk events.
- [ ] Run `python3 -m unittest tests.test_bounded_streams tests.test_event_limits -v`; confirm failures.
- [ ] Implement binary readers, replace `.read()` and unbounded line iteration, restrict probe show_entries to MediaInfo dependencies. Coalesce progress to at most 10 events/second per item while retaining terminal events; controller retains only bounded state per active job, not all events.
- [ ] Add `batch-results` events with `index`-identified result chunks ≤64 KiB. Keep the old terminal `paths` representation for batches that fit; oversized terminal summary uses additive `resultsChunked: true`, with all results already emitted. Update QML and protocol documentation together. Do not truncate valid result paths.
- [ ] Replace preview StdioCollector accumulation with per-event parsing and generation guards. Bound diagnostic/event histories in CliCall. Ensure downstream QML receives only controller-framed output, never raw worker stderr.
- [ ] Run the new tests plus probe, orientation, sequence, batch, toolbox and QML suites; verify long Unicode paths and large collections. Commit.

### Task 5: Preview admission, truthful outcomes and cleanup

**Files:** modify preview/controller/publish/errors and PreviewService/PreviewSlot/ConvertService; create `tests/test_worker_lifecycle.py`; extend QML lifecycle harnesses.

**Interfaces:** controller outcomes carry `reason` from the spec without renaming existing terminal events. `validate_preview(path: Path) -> tuple[int, int]` verifies ownership/type/size/PNG dimensions without decoding the source.

- [ ] Write failing tests for cancel during queue/start/encode, controller SIGKILL, timeout, output limit, confirmed OOM and external SIGKILL without OOM. Assert one terminal event, no current partial publication and no surviving job processes. Preserve earlier successful batch items.
- [ ] Add tests for stale preview completion, swapped input, overlarge generated preview, abandoned workdir, active workdir and symlink impostor.
- [ ] Run `python3 -m unittest tests.test_worker_lifecycle -v`; confirm missing behavior, then implement outcome attribution before scope collection, bounded cleanup and preview validation.
- [ ] Centralize automatic UI admission so probe/preview requests do not overlap for one UI. Preserve latest request and generation identity; new selections cancel old work. Generate preview without source metadata in private per-job staging, validate, atomically replace the owned slot.
- [ ] Run lifecycle, publish, privacy, preview, cancel-speed and isolated QML harnesses. Record actual parent/child cleanup timings and commit.

### Task 6: PNG bomb with a mandatory safety preflight

**Files:** create `tests/security/png_fixture.py`, `tests/security/test_png_bomb.py`, `tests/test_security_fixture.py`, `scripts/check-security.sh`.

**Interfaces:** `write_metadata_png(path: Path, expanded_bytes: int, chunk_bytes: int) -> dict` writes streaming bounded zTXt fixture and reports compressed/expanded byte counts and SHA256. Generator refuses expanded_bytes above 1 GiB. Security script exits nonzero when required live enforcement cannot be demonstrated.

- [ ] Write ordinary tests for PNG signature/chunk CRC/unique keywords, tiny valid image, declared expansion size and generator parameter caps; run `python3 -m unittest tests.test_security_fixture -v`, observe failure, implement and pass.
- [ ] Security script first validates cgroup with synthetic allocator, then generates 1 GiB-equivalent fixture in private temporary directory. Use 256 MiB worker budget and external 30-second watchdog that can stop the scope. Never run an unrestricted baseline decoder.
- [ ] Exercise real --probe, preview and isolated QML selection under test budget; accept controlled resource error or safe rejection/handling by patched FFmpeg. Assert no uncontrolled shell relay, no orphan tool, no partial output. Capture cgroup peak/events and outcome per case.
- [ ] Run `bash scripts/check-security.sh`; require actual execution, not skip, for release acceptance. Report enforcement test separately from bomb handling. Commit generator/tests and textual evidence only, never the bomb binary.

### Task 7: Integrated media and UI acceptance

**Files:** update `docs/validation/contained-workers.md`, `docs/guide.md`, dependency diagnostics; targeted regression tests only when uncovered behavior is found.

- [ ] Run `PYTHONDONTWRITEBYTECODE=1 bash scripts/check.sh` and the security script on final tree. New subprocess-facing tests must use the public controller for protection assertions; pure internal algorithm tests must not be mislabeled as confinement coverage.
- [ ] Compare integrated baseline and final tree on ordinary images, transparency, rotation, HDR/SDR, GIF, MP4/WebM, generated 4K and batch. Record command, input hash/type, elapsed time, peak RAM, output size/decode and applicable quality checks. Clearly distinguish generated from real user footage.
- [ ] Inspect rendered isolated window and keyboard flows, preview scrubbing, cancel/reopen and error recovery. Do not install into user shell. Fix regressions and rerun affected checks.
- [ ] Review final diff and evidence independently once; no claim of full sandboxing or marketplace approval. Commit docs and report branch/hash, checks, limitations and model/usage report if delegation was used.

## Execution recommendation

Native implementation by the lead, with one independent final review. Tasks depend closely on launch/lifetime/protocol contracts; serial execution avoids competing edits and repeated context transfer. No parallel implementation of shared files. A final reviewer may inspect read-only while the lead performs independent media/UI acceptance.

Plan status: ready for user review; no implementation has started.
