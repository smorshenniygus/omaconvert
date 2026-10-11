import QtQuick
import Quickshell
import "../../services" as Services

// Use the real CLI against a clip with visibly different first/later frames.
ShellRoot {
    id: root
    property int completed: 0
    Services.PreviewService { id: preview; executable: Quickshell.env("OMACONVERT_TEST_CLI") }
    Timer {
        interval: 400
        running: true
        onTriggered: {
            if (Quickshell.env("OMACONVERT_TEST_FIRST") === "default")
                preview.requestSource(Quickshell.env("OMACONVERT_TEST_INPUT"))
            else preview.requestSource(Quickshell.env("OMACONVERT_TEST_INPUT"), 2)
        }
    }
    Connections {
        target: preview
        function onSourceUrlChanged() {
            if (!preview.sourceUrl) return
            root.completed++
            if (root.completed === 1) next.start()
            else { console.log("PASS explicit zero refreshed the preview"); Qt.quit() }
        }
    }
    Timer {
        id: next
        interval: 150
        onTriggered: preview.requestSource(Quickshell.env("OMACONVERT_TEST_INPUT"), 0)
    }
    Timer {
        interval: 6000
        running: true
        onTriggered: { console.error("FAIL explicit zero did not refresh the preview"); Qt.quit() }
    }
}
