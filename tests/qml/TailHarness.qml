import QtQuick
import Quickshell
import "../../services" as Services

// The backend's last event has no trailing newline and the process exits
// right after it: the job must settle with that event already received.
ShellRoot {
    id: root
    property bool finished: false
    readonly property string helper: String(Qt.resolvedUrl("helpers/lifecycle_backend.py")).replace("file://", "")

    Services.ConvertService { id: service; executable: root.helper }

    Component.onCompleted: service.selectFile("tail")

    Timer {
        interval: 4000
        running: !root.finished
        onTriggered: { console.error("FAIL tail timeout"); Qt.quit() }
    }
    Connections {
        target: service
        function onBusyChanged() {
            if (service.busy || root.finished) return
            root.finished = true
            if (service.metadata && service.metadata.path === "tail" && service.error === "")
                console.log("PASS last line without newline is received before settling")
            else
                console.error("FAIL metadata=" + JSON.stringify(service.metadata) + " error=" + service.error)
            Qt.quit()
        }
    }
}
