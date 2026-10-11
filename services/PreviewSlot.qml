pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import "Model.js" as Model

// One cached thumbnail: a fixed, owner-only file and the process that writes
// or deletes it. Deleting runs on the same Process, so it can never race a
// newer preview of this slot. A generation counter discards completions
// that belong to an older request.
Item {
    id: slot
    required property string executable
    required property string path      // the cache file this slot owns
    // Re-rendering the file already shown (scrubbing) keeps the old frame
    // until the new one arrives, so dragging feels instant. A new file
    // always clears the view first: no stale frames.
    property bool keepFrameForSameInput: false

    property string url: ""
    property bool loading: false
    property int imageWidth: 0
    property int imageHeight: 0
    property int generation: 0
    property string lastKey: ""        // last request, to skip duplicate work
    property string shownInput: ""

    // `key` identifies the request (input plus position); `extra` are more
    // CLI arguments such as --preview-position.
    function request(input, key, extra) {
        if (!input || !slot.executable) return
        if (key === lastKey && (url !== "" || loading)) return
        lastKey = key
        generation++
        if (!keepFrameForSameInput || input !== shownInput) {
            shownInput = input
            url = ""
            imageWidth = 0
            imageHeight = 0
        }
        loading = true
        start(["--preview", input, "--preview-output", slot.path,
               "--preview-size", String(Model.previewSize())].concat(extra || []))
    }
    function clear() {
        lastKey = ""
        shownInput = ""
        generation++
        url = ""
        imageWidth = 0
        imageHeight = 0
        loading = false
        start(["--forget-preview", slot.path])
    }
    function start(args) {
        if (!slot.executable) return
        if (job.running) job.running = false
        job.generation = generation
        job.command = ["python3", slot.executable].concat(args)
        job.running = true
    }
    function finished(text, generation) {
        if (generation !== slot.generation) return // stale completion after the input changed
        var preview = null
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var event = Model.eventFromLine(lines[i])
            if (event && event.event === "preview") preview = event
        }
        loading = false
        if (preview && preview.path) {
            imageWidth = preview.width || 0
            imageHeight = preview.height || 0
            url = Model.fileUri(slot.path) + "?g=" + generation
        }
    }

    Process {
        id: job
        property int generation: 0
        // Generation of the process actually running. A new request only
        // queues its command: Quickshell starts it after the old process
        // exits, and the old one's output arrives after `generation` moved on.
        property int startedGeneration: -1
        onStarted: job.startedGeneration = job.generation
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: slot.finished(text, job.startedGeneration)
        }
        // qmllint disable signal-handler-parameters
        onExited: (code) => {
            // Stream finish carries the result; this only clears a hung spinner.
            if (job.startedGeneration === slot.generation && slot.loading && code !== 0)
                slot.loading = false
        }
        // qmllint enable signal-handler-parameters
    }
    Component.onDestruction: if (job.running) job.running = false
}
