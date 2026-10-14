import QtQuick
import Quickshell
import "../../services" as Services
ShellRoot {
    id: root
    property int stage: 0
    property int ticks: 0
    property bool requested: false
    Services.ConvertService {
        id: service
        executable: Quickshell.env("OMACONVERT_TEST_CLI")
        onMetadataChanged: {
            if (metadata) { root.requested = true; preview.requestSource(inputPath, undefined, false, metadata) }
        }
    }
    Services.PreviewService { id: preview; executable: Quickshell.env("OMACONVERT_TEST_CLI") }
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            root.ticks++
            if (root.stage === 0) {
                root.stage = 1
                service.selectFile(Quickshell.env("OMACONVERT_TEST_BOMB"))
            } else if (root.stage === 1 && root.requested && !preview.sourceLoading) {
                root.stage = 2
                root.requested = false
                service.selectFile(Quickshell.env("OMACONVERT_TEST_GOOD"))
            } else if (root.stage === 2 && preview.sourceUrl !== "" && !preview.sourceLoading) {
                console.log("PASS hostile selection recovered; responsive ticks=" + root.ticks)
                Qt.quit()
            }
            if (root.ticks >= 250) { console.error("FAIL hostile selection did not recover: " + service.error); Qt.quit() }
        }
    }
}
