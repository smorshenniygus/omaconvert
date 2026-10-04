pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Async bounded previews (DEV-04). Each slot writes to one fixed cache file
// so temp previews never accumulate: at most src-preview.png + res-preview.png.
// Generation counters discard stale completions after the input changes.
Item {
    id: root
    required property string executable

    readonly property string cacheBase: (Quickshell.env("XDG_CACHE_HOME")
        || ((Quickshell.env("HOME") || "/tmp") + "/.cache")) + "/omaconvert/previews"
    readonly property string sourcePath: cacheBase + "/src-preview.png"
    readonly property string resultPath: cacheBase + "/res-preview.png"

    property string sourceUrl: ""
    property string resultUrl: ""
    property bool sourceLoading: false
    property bool resultLoading: false
    property int sourceWidth: 0
    property int sourceHeight: 0
    property int resultWidth: 0
    property int resultHeight: 0

    property int sourceGeneration: 0
    property int resultGeneration: 0
    // Last requested inputs, used to skip duplicate work.
    property string lastSourceInput: ""
    property string lastResultInput: ""
    // Source file of the currently shown thumbnail. A new file clears the
    // view (no stale frames); scrubbing the same file keeps the old frame
    // until the new one arrives so dragging feels instant.
    property string shownSourcePath: ""

    function cacheFileUri(path, generation) {
        return Model.fileUri(path) + "?g=" + generation
    }
    function requestSource(inputPath, position) {
        var pos = Number(position || 0)
        if (!inputPath || !root.executable) return
        var key = inputPath + "@" + (pos > 0 ? pos.toFixed(1) : "0")
        if (key === lastSourceInput && (sourceUrl !== "" || sourceLoading)) return
        lastSourceInput = key
        sourceGeneration++
        var generation = sourceGeneration
        if (inputPath !== shownSourcePath) {
            shownSourcePath = inputPath
            sourceUrl = ""
            sourceWidth = 0
            sourceHeight = 0
        }
        sourceLoading = true
        if (sourceJob.running) sourceJob.running = false
        sourceJob.generation = generation
        sourceJob.command = ["python3", root.executable, "--preview", inputPath,
                             "--preview-output", root.sourcePath, "--preview-size", "320"]
        if (pos > 0) sourceJob.command = sourceJob.command.concat(["--preview-position", String(pos)])
        sourceJob.running = true
    }
    function requestResult(inputPath) {
        if (!inputPath || !root.executable) return
        if (inputPath === lastResultInput && (resultUrl !== "" || resultLoading)) return
        lastResultInput = inputPath
        resultGeneration++
        var generation = resultGeneration
        resultUrl = ""
        resultWidth = 0
        resultHeight = 0
        resultLoading = true
        if (resultJob.running) resultJob.running = false
        resultJob.generation = generation
        resultJob.command = ["python3", root.executable, "--preview", inputPath,
                             "--preview-output", root.resultPath, "--preview-size", "320"]
        resultJob.running = true
    }
    function clearSource() {
        lastSourceInput = ""
        shownSourcePath = ""
        sourceGeneration++
        sourceUrl = ""
        sourceWidth = 0
        sourceHeight = 0
        sourceLoading = false
        if (sourceJob.running) sourceJob.running = false
    }
    function clearResult() {
        lastResultInput = ""
        resultGeneration++
        resultUrl = ""
        resultWidth = 0
        resultHeight = 0
        resultLoading = false
        if (resultJob.running) resultJob.running = false
    }
    function clearAll() { clearSource(); clearResult() }

    function handleFinished(text, generation, isSource) {
        var current = isSource ? sourceGeneration : resultGeneration
        if (generation !== current) return // stale completion after input change
        var preview = null
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var event = Model.eventFromLine(lines[i])
            if (event && event.event === "preview") preview = event
        }
        if (isSource) {
            sourceLoading = false
            if (preview && preview.path) {
                sourceWidth = preview.width || 0
                sourceHeight = preview.height || 0
                sourceUrl = cacheFileUri(root.sourcePath, generation)
            }
        } else {
            resultLoading = false
            if (preview && preview.path) {
                resultWidth = preview.width || 0
                resultHeight = preview.height || 0
                resultUrl = cacheFileUri(root.resultPath, generation)
            }
        }
    }

    Process {
        id: sourceJob
        property int generation: 0
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.handleFinished(text, sourceJob.generation, true)
        }
        // qmllint disable signal-handler-parameters
        onExited: (code) => {
            // Stream finish carries the result; this only clears a hung spinner.
            if (sourceJob.generation === root.sourceGeneration && root.sourceLoading && code !== 0)
                root.sourceLoading = false
        }
        // qmllint enable signal-handler-parameters
    }
    Process {
        id: resultJob
        property int generation: 0
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.handleFinished(text, resultJob.generation, false)
        }
        // qmllint disable signal-handler-parameters
        onExited: (code) => {
            if (resultJob.generation === root.resultGeneration && root.resultLoading && code !== 0)
                root.resultLoading = false
        }
        // qmllint enable signal-handler-parameters
    }
    Component.onDestruction: {
        if (sourceJob.running) sourceJob.running = false
        if (resultJob.running) resultJob.running = false
    }
}
