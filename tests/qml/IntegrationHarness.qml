import QtQuick
import Quickshell
import "../../services" as Services

// The window's utility calls (status, capabilities, Open With, hotkey,
// paste) explain every failure: whatever the backend does wrong, the
// matching control gets a message, keeps its old state and can be used
// again. A healthy backend afterwards clears what the failure left.
ShellRoot {
    id: root
    readonly property string folder: String(Qt.resolvedUrl("helpers/")).replace("file://", "")
    property string pasteMessage: ""
    property int pastedCount: 0
    property var pastedEvent: null
    property var steps: []
    property int step: -1
    property real stepStarted: 0

    function stub(mode) { return root.folder + "cli_backend_" + mode + ".py" }

    Services.ConvertService { id: svc; executable: root.stub("ok") }
    Connections {
        target: svc
        function onPasteFailed(message) { root.pasteMessage = message }
        function onPasted(result) { root.pastedCount++; root.pastedEvent = result }
    }

    function fail(message) { console.error("FAIL " + message); Qt.quit() }
    function must(condition, message) { if (!condition) { fail(message); return false } return true }
    function add(label, start, until) { steps.push({ label: label, start: start, until: until }) }

    // One broken backend: every utility call fails with a message of its own.
    function brokenBackend(mode, expected, details) {
        add(mode + ": status fails and says why", () => {
            svc.executable = root.stub(mode)
            svc.error = "an earlier problem"
            svc.loadStatus()
        }, () => svc.statusError !== "")
        add(mode + ": status", () => {
            must(svc.statusError.indexOf(expected) >= 0, mode + ": status error " + svc.statusError)
            must(svc.error === "an earlier problem", mode + ": an existing error was replaced: " + svc.error)
            must(svc.capabilities === null && svc.openWith === null && svc.hotkey === null, mode + ": state invented")
            svc.error = ""
            svc.statusError = ""
            svc.loadStatus()
        }, () => svc.statusError !== "" && svc.error === svc.statusError)
        add(mode + ": status is shown", () => {
            must(svc.details.indexOf(details) >= 0, mode + ": details " + JSON.stringify(svc.details))
            svc.setOpenWith(true)
        }, () => svc.openWithError !== "")
        add(mode + ": open with", () => {
            must(svc.openWithError.indexOf(details) >= 0 || svc.openWithError.indexOf(expected) >= 0,
                 mode + ": open with error " + svc.openWithError)
            must(svc.openWith === null, mode + ": open with state changed")
            svc.setOpenWith(true) // the call must be free again
        }, () => svc.openWithError !== "")
        add(mode + ": open with again", () => {
            svc.setHotkey(true)
        }, () => svc.hotkeyError !== "")
        add(mode + ": hotkey", () => {
            must(svc.hotkeyError.indexOf(details) >= 0 || svc.hotkeyError.indexOf(expected) >= 0,
                 mode + ": hotkey error " + svc.hotkeyError)
            must(svc.hotkey === null, mode + ": hotkey state changed")
            svc.error = ""
            svc.paste()
        }, () => root.pasteMessage !== "")
        add(mode + ": paste", () => {
            must(root.pasteMessage.indexOf(details) >= 0 || root.pasteMessage.indexOf(expected) >= 0,
                 mode + ": paste message " + root.pasteMessage)
            must(root.pastedCount === 0, mode + ": paste reported a result")
            root.pasteMessage = ""
            svc.statusError = ""
            svc.error = ""
            svc.loadCapabilities()
        }, () => svc.statusError !== "")
        add(mode + ": capabilities", () => {
            must(svc.capabilities === null, mode + ": capabilities invented")
            root.pasteMessage = ""
            svc.paste() // and again
        }, () => root.pasteMessage !== "")
    }

    Component.onCompleted: {
        brokenBackend("exit", "stopped unexpectedly", "boom: the stub failed")
        brokenBackend("empty", "without an answer", "printed nothing")
        brokenBackend("malformed", "could not read", "this is not json")
        brokenBackend("error", "Could not change the Open With entry.", "read-only file system")

        add("a healthy backend: status clears the failure", () => {
            svc.executable = root.stub("ok")
            root.pasteMessage = ""
            svc.statusError = "left over"
            svc.error = "left over"
            svc.details = "stderr of the failure"
            svc.loadStatus()
        }, () => svc.backendVersion !== "")
        add("a healthy backend: status", () => {
            must(svc.backendVersion === "9.9.9", "version " + svc.backendVersion)
            must(svc.error === "" && svc.details === "" && svc.statusError === "",
                 "failure not cleared: " + svc.error + " / " + svc.details)
            must(svc.openWith && svc.openWith.enabled === false, "open with " + JSON.stringify(svc.openWith))
            must(svc.hotkey && svc.hotkey.available === true, "hotkey " + JSON.stringify(svc.hotkey))
            svc.openWithError = "left over"
            svc.setOpenWith(true)
        }, () => svc.openWith && svc.openWith.enabled === true)
        add("a healthy backend: open with", () => {
            must(svc.openWithError === "", "open with error kept: " + svc.openWithError)
            svc.hotkeyError = "left over"
            svc.setHotkey(true)
        }, () => svc.hotkey && svc.hotkey.enabled === true)
        add("a healthy backend: hotkey", () => {
            must(svc.hotkeyError === "", "hotkey error kept: " + svc.hotkeyError)
            svc.paste()
        }, () => root.pastedCount === 1)
        add("a healthy backend: paste", () => {
            must(root.pastedEvent.kind === "text" && root.pastedEvent.text === "pasted words", "paste " + JSON.stringify(root.pastedEvent))
            must(root.pasteMessage === "", "paste failure reported")
            svc.loadCapabilities()
        }, () => svc.capabilities !== null)
        add("done", () => {
            console.log("PASS utility calls explain their failures")
            Qt.quit()
        }, () => true)
        stepTimer.start()
    }

    Timer {
        id: stepTimer
        interval: 30
        repeat: true
        onTriggered: {
            if (root.step >= 0 && root.step < root.steps.length) {
                var running = root.steps[root.step]
                if (!running.until()) {
                    if (Date.now() - root.stepStarted > 4000) root.fail("timeout waiting after: " + running.label)
                    return
                }
            }
            root.step++
            if (root.step >= root.steps.length) return
            root.stepStarted = Date.now()
            root.steps[root.step].start()
        }
    }
    Timer { interval: 60000; running: true; onTriggered: root.fail("overall timeout at step " + root.step) }
}
