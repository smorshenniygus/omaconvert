import QtQuick
import Quickshell
import "../../services" as Services

// A batch row that changes keeps its delegate; replacing the list with the
// same files updates rows in place, a different list rebuilds them.
ShellRoot {
    id: root
    Services.ConvertService { id: service; executable: "/bin/false" }
    Item {
        Repeater {
            id: rows
            model: service.batchModel
            delegate: Item {
                required property string path
                required property string status
                required property real outputBytes
            }
        }
    }
    function fail(message) { console.error("FAIL " + message); Qt.quit() }
    Timer { interval: 50; running: true; onTriggered: root.check() }
    Timer { interval: 5000; running: true; onTriggered: root.fail("timeout") }
    function check() {
        service.replaceBatch([{ path: "/a.png", status: "reading" }, { path: "/b.png", status: "reading" }])
        if (rows.count !== 2) return fail("rows " + rows.count)
        var first = rows.itemAt(0)
        service.updateBatch(0, { ok: true, status: "done", outputBytes: 42 })
        if (rows.itemAt(0) !== first) return fail("updateBatch recreated the row")
        if (first.status !== "done" || first.outputBytes !== 42) return fail("row not updated: " + first.status)
        if (service.batch[0].status !== "done" || service.batch[1].status !== "reading") return fail("array out of step")
        service.replaceBatch(service.batch.map(item => Object.assign({}, item, { status: "stopped" })))
        if (rows.itemAt(0) !== first || first.status !== "stopped") return fail("same files rebuilt the rows")
        service.replaceBatch([])
        if (rows.count !== 0 || service.isBatch) return fail("clearing left rows")
        console.log("PASS batch rows update in place")
        Qt.quit()
    }
}
