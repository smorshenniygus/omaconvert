pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import "Model.js" as Model

Item {
    id: root
    required property string executable
    readonly property bool busy: currentJob !== null || transitioning
    property bool starting: false
    property bool cancelling: false
    property string operation: ""
    property string inputPath: ""
    property var metadata: null
    property var result: null
    property string error: ""
    property string details: ""
    property string notice: ""
    property string phase: ""
    property real progress: 0
    property var candidate: null
    // Every size the search measured for this job, oldest first (at most 6).
    property var candidates: []
    // Date.now() when the current conversion started; 0 when idle.
    property real startedAt: 0
    property int currentPass: 0
    property bool terminalEvent: false
    property bool dependenciesReady: true
    // `capabilities` event: which formats this FFmpeg can write. Asked once
    // per session by check(); null until then (Model.js falls back).
    property var capabilities: null
    // Version reported by the CLI; differs from Model.VERSION when the shell
    // still runs cached QML from before a plugin update.
    property string backendVersion: ""
    // Desktop entry for "Open With" and app search: null until asked, then
    // {enabled, path}. Changed only by the user (setOpenWith).
    property var openWith: null
    property string openWithError: ""
    property int lastExit: 0

    property int nextGeneration: 0
    property var currentJob: null
    property string pendingSelection: ""
    property bool transitioning: false

    function isCurrent(job) { return currentJob === job }
    function launch(args, kind) {
        if (currentJob !== null) return
        error = ""
        details = ""
        terminalEvent = false
        cancelling = false
        operation = kind
        starting = true
        lastExit = 0
        var job = jobComponent.createObject(root, {
            generation: ++nextGeneration,
            commandLine: ["python3", executable].concat(args)
        })
        currentJob = job
        currentJob.start()
    }
    function check() { launch(["--check"], "check") }
    // Independent of the job queue: a probe/convert must not cancel it, and
    // it must not cancel them. At most once per session unless it failed.
    function loadCapabilities() {
        if (capabilities !== null || capabilitiesProcess.running) return
        capabilitiesProcess.command = ["python3", executable, "--capabilities"]
        capabilitiesProcess.running = true
    }
    function beginProbe(path) {
        inputPath = path
        metadata = null
        result = null
        phase = "Reading media…"
        launch(["--probe", path], "probe")
    }
    function selectFile(path) {
        if (!path) return
        if (busy) {
            pendingSelection = path
            inputPath = path
            metadata = null
            result = null
            phase = "Waiting for the previous task to stop…"
            cancel(false)
            return
        }
        pendingSelection = ""
        beginProbe(path)
    }
    // outputDir: destination folder, or "" to save next to the source.
    // sequenceFps: null for one file; 0 or a rate for a PNG sequence folder.
    function convert(format, mode, size, unit, preset, preference, trimStart, trimEnd, outputDir, sequenceFps) {
        if (busy || !metadata || !dependenciesReady) return
        result = null
        candidate = null
        candidates = []
        startedAt = Date.now()
        progress = 0
        currentPass = 0
        phase = mode === "target" ? "Finding the best quality…" : "Converting…"
        launch(Model.arguments(inputPath, format, mode, size, unit, preset, preference,
                               trimStart, trimEnd, metadata ? metadata.duration : 0, outputDir || "",
                               sequenceFps), "convert")
    }
    // User cancellation and overlay close discard a queued file. selectFile()
    // keeps it by passing false while replacing an in-flight request.
    function cancel(clearPending) {
        if (clearPending === undefined) clearPending = true
        if (clearPending) pendingSelection = ""
        if (!busy) return
        cancelling = true
        phase = "Cancelling…"
        if (currentJob) currentJob.stop()
    }
    function receive(job, line) {
        if (!isCurrent(job)) return
        var event = Model.eventFromLine(line)
        if (!event) {
            if (line.trim()) details = (details + "\n" + line).slice(-16000)
            return
        }
        if (event.event === "probe") metadata = event
        else if (event.event === "dependencies") {
            dependenciesReady = event.ok !== false
            if (event.version) backendVersion = String(event.version)
            notice = event.gifsicle === false ? "Tip: install gifsicle to make GIFs a little smaller." : ""
        } else if (event.event === "warning") notice = event.message || ""
        else if (event.event === "candidate") { candidate = event; candidates = candidates.concat([event]).slice(-6) }
        else if (event.event === "complete") {
            job.terminalEvent = true
            terminalEvent = true
            result = event
            progress = 1
            phase = "Done"
        } else if (event.event === "error") {
            job.terminalEvent = true
            terminalEvent = true
            error = event.message || "Conversion failed."
            details = event.details || details
            if (operation === "check") dependenciesReady = false
        } else if (event.event === "cancelled") {
            job.terminalEvent = true
            terminalEvent = true
            phase = "Cancelled — your source is unchanged."
        } else if (!cancelling) {
            if (event.event === "analyzing") phase = "Finding the best quality…"
            if (event.event === "encoding") phase = "Converting…"
            if (event.event === "optimizing") phase = "Optimizing GIF…"
        }
        if (!cancelling && typeof event.progress === "number") progress = Math.max(0, Math.min(1, event.progress))
        if (typeof event.pass === "number") currentPass = event.pass
    }
    function exited(job, exitCode) {
        if (!isCurrent(job)) return
        starting = false
        lastExit = exitCode
        job.exitDone = true
        job.maybeSettle()
    }
    function startFailed(job) {
        if (!isCurrent(job) || job.started) return
        starting = false
        job.terminalEvent = true
        error = "Could not start Python 3. Check that python3 and the plugin backend are installed."
        job.exitDone = true
        job.stdoutDone = true
        job.maybeSettle()
    }
    function settle(job) {
        if (!isCurrent(job)) { job.destroy(); return }
        // Finalize only after process exit AND the stdout stream has drained.
        // Each launch owns its parsers; old objects cannot affect a new job.
        var wasCancelling = cancelling
        var nextPath = pendingSelection
        if (nextPath) transitioning = true
        currentJob = null
        starting = false
        if (wasCancelling && !result) phase = "Cancelled — your source is unchanged."
        else if (!job.terminalEvent && (lastExit !== 0 || (operation === "convert" && !result)))
            error = "The converter stopped unexpectedly. See Details and try again."
        cancelling = false
        pendingSelection = ""
        job.destroy()
        if (nextPath) beginProbe(nextPath)
        transitioning = false
    }

    // Hotkey block in ~/.config/hypr/bindings.lua: null until asked, then
    // {enabled, keys, free, available}. Changed only by the user.
    property var hotkey: null
    property string hotkeyError: ""
    function loadHotkey() { runHotkey("status") }
    function setHotkey(enabled) { runHotkey(enabled ? "on" : "off") }
    function runHotkey(action) {
        if (hotkeyProcess.running) return
        hotkeyError = ""
        hotkeyProcess.command = ["python3", executable, "--hotkey", action]
        hotkeyProcess.running = true
    }
    // Ctrl+V: {kind: "file"|"text"|"none", path, text} arrives through pasted().
    signal pasted(var result)
    function paste() {
        if (pasteProcess.running) return
        pasteProcess.command = ["python3", executable, "--paste"]
        pasteProcess.running = true
    }

    // Like capabilities: independent of the job queue.
    function loadOpenWith() { runOpenWith("status") }
    function setOpenWith(enabled) { runOpenWith(enabled ? "on" : "off") }
    function runOpenWith(action) {
        if (openWithProcess.running) return
        openWithError = ""
        openWithProcess.command = ["python3", executable, "--open-with", action]
        openWithProcess.running = true
    }

    Process {
        id: hotkeyProcess
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var lines = text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var event = Model.eventFromLine(lines[i])
                    if (event && event.event === "hotkey") root.hotkey = event
                    else if (event && event.event === "error") root.hotkeyError = event.details || event.message
                }
            }
        }
    }
    Process {
        id: pasteProcess
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var lines = text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var event = Model.eventFromLine(lines[i])
                    if (event && event.event === "paste") root.pasted(event)
                }
            }
        }
    }

    Process {
        id: openWithProcess
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var lines = text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var event = Model.eventFromLine(lines[i])
                    if (event && event.event === "open-with") root.openWith = event
                    else if (event && event.event === "error") root.openWithError = event.details || event.message
                }
            }
        }
    }

    Process {
        id: capabilitiesProcess
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var lines = text.split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var event = Model.eventFromLine(lines[i])
                    if (event && event.event === "capabilities") root.capabilities = event
                }
            }
        }
    }

    Component {
        id: jobComponent
        Item {
            id: job
            required property int generation
            required property var commandLine
            property bool started: false
            property bool terminalEvent: false
            property bool exitDone: false
            property bool stdoutDone: false
            property int consumed: 0

            function start() {
                process.command = commandLine
                process.running = true
                startup.restart()
            }
            function stop() {
                if (process.running) process.signal(15)
            }
            function maybeSettle() {
                if (exitDone && stdoutDone) root.settle(job)
            }
            function consume(text, finalChunk) {
                var end = finalChunk ? text.length : text.lastIndexOf("\n") + 1
                if (end <= consumed) return
                var lines = text.slice(consumed, end).split("\n")
                consumed = end
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i].trim()) root.receive(job, lines[i])
                }
            }

            Process {
                id: process
                stdout: StdioCollector {
                    waitForEnd: false
                    onDataChanged: job.consume(text, false)
                    onStreamFinished: {
                        job.consume(text, true)
                        job.stdoutDone = true
                        job.maybeSettle()
                    }
                }
                stderr: SplitParser {
                    onRead: line => {
                        if (root.isCurrent(job)) root.details = (root.details + "\n" + line).slice(-16000)
                    }
                }
                onStarted: {
                    job.started = true
                    startup.stop()
                    if (root.isCurrent(job)) root.starting = false
                    if (root.isCurrent(job) && root.cancelling) signal(15)
                }
                // Installed Quickshell metadata omits QProcess::ExitStatus.
                // qmllint disable signal-handler-parameters
                onExited: exitCode => {
                    startup.stop()
                    root.exited(job, exitCode)
                }
                // qmllint enable signal-handler-parameters
            }
            Timer {
                id: startup
                interval: 1500
                onTriggered: {
                    if (!job.started && !process.running) root.startFailed(job)
                }
            }
        }
    }
    Component.onDestruction: {
        pendingSelection = ""
        if (currentJob) currentJob.stop()
    }
}
