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
                required property real progress
            }
        }
    }
    function fail(message) { console.error("FAIL " + message); Qt.quit() }
    Timer { interval: 50; running: true; onTriggered: root.check() }
    Timer { interval: 5000; running: true; onTriggered: root.fail("timeout") }
    QtObject { id: fakeJob; property bool terminalEvent: false }
    // Still images convert several at a time: each row follows its own
    // file, the screen details the file started last.
    function parallel() {
        var paths = ["/a.png", "/b.png", "/c.png"]
        service.replaceBatch(paths.map(path => ({ path: path, ok: true, status: "queued" })))
        service.batchOrder = paths
        service.operation = "batch"
        service.currentJob = fakeJob
        var send = fields => service.receive(fakeJob, JSON.stringify(fields))
        send({ event: "item", index: 0, total: 3, path: "/a.png" })
        send({ event: "item", index: 1, total: 3, path: "/b.png" })
        send({ event: "encoding", index: 0, progress: 0.5 })
        send({ event: "candidate", index: 0, width: 10, height: 10, estimated_bytes: 5, progress: 0.6 })
        send({ event: "encoding", index: 1, progress: 0.25 })
        send({ event: "encoding", index: 1, progress: 0.1 })
        // A row never moves back: 0.1 after 0.25 keeps 0.25.
        var ok = rows.itemAt(0).progress === 0.5 && rows.itemAt(1).progress === 0.25 && rows.itemAt(2).status === "queued"
        if (!ok) { fail("row progress " + rows.itemAt(0).progress + " " + rows.itemAt(1).progress); return false }
        if (service.progress !== 0.1 || service.candidates.length !== 0) { fail("screen followed an older file"); return false }
        send({ event: "item-complete", index: 0, source: "/a.png", path: "/a.jpg", bytes: 3 })
        if (rows.itemAt(0).status !== "done" || rows.itemAt(0).progress !== 1 || rows.itemAt(1).status !== "working") { fail("completion"); return false }
        service.currentJob = null
        return true
    }
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
        if (!root.parallel()) return
        console.log("PASS batch rows update in place")
        Qt.quit()
    }
}
