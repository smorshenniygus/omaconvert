import QtQuick
import Quickshell
import "../../services" as Services

// Opens a preview, then (when OMACONVERT_TEST_CLEAR=1) clears it, and reports
// the cache path; tests/test_qml_lifecycle.py checks the file on disk.
ShellRoot {
    id: root
    readonly property bool clearAfter: Quickshell.env("OMACONVERT_TEST_CLEAR") === "1"
    property bool done: false

    Services.PreviewService { id: preview; executable: Quickshell.env("OMACONVERT_TEST_CLI") }

    Timer {
        interval: 400
        running: true
        onTriggered: preview.requestSource(Quickshell.env("OMACONVERT_TEST_INPUT"))
    }
    Connections {
        target: preview
        function onSourceUrlChanged() {
            if (preview.sourceUrl === "" || root.done) return
            root.done = true
            console.log("READY " + preview.sourcePath)
            if (root.clearAfter) { preview.clearSource(); quitLater.start() }
            else Qt.quit()
        }
    }
    Timer { id: quitLater; interval: 1500; onTriggered: { console.log("CLEARED"); Qt.quit() } }
    Timer {
        interval: 8000
        running: true
        onTriggered: { console.error("FAIL preview timeout"); Qt.quit() }
    }
}
