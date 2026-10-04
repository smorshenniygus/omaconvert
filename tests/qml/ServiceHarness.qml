import QtQuick
import Quickshell
import "../../services" as Services

ShellRoot {
    id: root
    property bool replacementRequested: false
    property bool finished: false
    readonly property string helper: String(Qt.resolvedUrl("helpers/lifecycle_backend.py")).replace("file://", "")

    Services.ConvertService { id: service; executable: root.helper }

    Component.onCompleted: service.selectFile("slow")

    Timer {
        interval: 50
        running: true
        onTriggered: {
            root.replacementRequested = true
            service.selectFile("fast")
        }
    }
    Timer {
        interval: 2500
        running: !root.finished
        onTriggered: {
            console.error("FAIL lifecycle timeout: " + service.metadata)
            Qt.quit()
        }
    }
    Connections {
        target: service
        function onBusyChanged() {
            if (!root.replacementRequested || service.busy || root.finished) return
            root.finished = true
            if (service.metadata && service.metadata.path === "fast" && service.error === "")
                console.log("PASS latest queued selection wins")
            else
                console.error("FAIL expected fast metadata, got " + service.metadata + " error=" + service.error)
            Qt.quit()
        }
    }
}
