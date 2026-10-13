import QtQuick
import Quickshell
import "../../services" as Services

// Every accepted CliCall ends exactly once, with a clear outcome, whatever
// the backend does: answers, prints nothing or rubbish, fails, crashes or
// never starts. `busy` is released before the outcome is announced.
ShellRoot {
    id: root
    readonly property string folder: String(Qt.resolvedUrl("helpers/")).replace("file://", "")
    property var received: []
    property int finishedCount: 0
    property int failedCount: 0
    property bool busyAtFinish: true
    property var last: null
    property int index: -1
    property var current: null
    property real startedAt: 0

    function stub(mode) { return root.folder + "cli_backend_" + mode + ".py" }

    // `reason`: "" for success. `names`: the events passed on, in order.
    readonly property var scenarios: [
        { name: "answer", mode: "ok", expect: "status", args: ["--status"], reason: "", names: ["status"] },
        { name: "noise before the answer", mode: "noisy", expect: "status", args: ["--status"], reason: "", names: ["status"] },
        { name: "answer needs no expectation", mode: "ok", expect: "", args: ["--status"], reason: "", names: ["status"] },
        { name: "silence needs no expectation", mode: "empty", expect: "", args: ["--status"], reason: "", names: [] },
        { name: "empty stdout", mode: "empty", expect: "status", args: ["--status"], reason: "no-response", names: [],
          details: "printed nothing", exitCode: 0 },
        { name: "another event only", mode: "other", expect: "status", args: ["--status"], reason: "no-response",
          names: ["dependencies"], details: "dependencies instead of status" },
        { name: "malformed JSON", mode: "malformed", expect: "status", args: ["--status"], reason: "malformed",
          names: [], details: "this is not json" },
        { name: "nonzero exit with stderr", mode: "exit", expect: "status", args: ["--status"], reason: "exit",
          names: [], details: "boom: the stub failed", exitCode: 3 },
        { name: "stderr stays bounded", mode: "hugeerr", expect: "status", args: ["--status"], reason: "exit",
          names: [], exitCode: 1, maxDetails: 4000 },
        { name: "error event", mode: "error", expect: "open-with", args: ["--open-with", "on"], reason: "error",
          names: ["error"], message: "Could not change the Open With entry.", details: "read-only file system",
          summary: "read-only file system", exitCode: 2 },
        { name: "answer, then a crash", mode: "late", expect: "status", args: ["--status"], reason: "exit",
          names: ["status"], exitCode: 1 },
        { name: "killed", mode: "crash", expect: "status", args: ["--status"], reason: "exit", names: [] },
        { name: "missing backend script", mode: "ok", expect: "status", args: ["--status"], reason: "exit", names: [],
          executable: "/nonexistent/omaconvert", details: "can't open file", exitCode: 2 },
        { name: "missing interpreter", mode: "ok", expect: "status", args: ["--status"], reason: "start", names: [],
          interpreter: "/nonexistent/python3", exitCode: -1 }
    ]

    Services.CliCall {
        id: call
        executable: root.stub("ok")
        onEvent: event => root.received = root.received.concat([event.event])
        onFailed: outcome => root.failedCount++
        onFinished: outcome => {
            root.finishedCount++
            root.last = outcome
            root.busyAtFinish = call.busy
        }
    }

    function fail(message) { console.error("FAIL " + message); Qt.quit() }
    function same(a, b) { return JSON.stringify(a) === JSON.stringify(b) }
    function sameFields(a, b) {
        var keys = Object.keys(a || {})
        return keys.length === Object.keys(b || {}).length && keys.every(key => a[key] === b[key])
    }

    function begin() {
        index++
        if (index >= scenarios.length) return busyChecks()
        current = scenarios[index]
        received = []
        finishedCount = 0
        failedCount = 0
        last = null
        busyAtFinish = true
        call.executable = current.executable || stub(current.mode)
        call.interpreter = current.interpreter || "python3"
        call.expect = current.expect
        startedAt = Date.now()
        if (!call.run(current.args)) return fail(current.name + ": run() refused an idle call")
        phase.restart()
    }

    // The outcome is checked after a pause: a second settle (the process
    // exiting after it was declared unstartable, a late running=false) would
    // show up as a second `finished`.
    function check() {
        var s = current
        var o = last
        if (finishedCount !== 1) return fail(s.name + ": finished " + finishedCount + " times")
        if (!o) return fail(s.name + ": no outcome")
        if (call.busy || root.busyAtFinish) return fail(s.name + ": still busy when finished")
        if (o.ok !== (s.reason === "") || o.reason !== s.reason)
            return fail(s.name + ": outcome " + JSON.stringify(o))
        if (failedCount !== (o.ok ? 0 : 1)) return fail(s.name + ": failed emitted " + failedCount + " times")
        if (!same(received, s.names)) return fail(s.name + ": events " + JSON.stringify(received))
        if (s.exitCode !== undefined && o.exitCode !== s.exitCode)
            return fail(s.name + ": exit code " + o.exitCode)
        if (s.details && o.details.indexOf(s.details) < 0) return fail(s.name + ": details " + JSON.stringify(o.details))
        if (s.maxDetails && (o.details.length > s.maxDetails || o.details.length < 100))
            return fail(s.name + ": details length " + o.details.length)
        if (s.message && o.message !== s.message) return fail(s.name + ": message " + o.message)
        if (s.summary && o.summary !== s.summary) return fail(s.name + ": summary " + o.summary)
        if (!o.ok && (!o.message || !o.summary)) return fail(s.name + ": failure without words " + JSON.stringify(o))
        if (!sameFields(call.outcome, o)) return fail(s.name + ": outcome property")
        begin()
    }

    // Asking again while a call runs is refused; once it has ended it is
    // accepted again, and a refused ask does not disturb the running call.
    function busyChecks() {
        call.executable = stub("slow")
        call.interpreter = "python3"
        call.expect = "status"
        received = []
        finishedCount = 0
        failedCount = 0
        if (!call.run(["--status"])) return fail("slow: refused")
        if (!call.busy) return fail("busy not set by run()")
        if (call.run(["--status"])) return fail("a second run() was accepted while busy")
        late.start()
    }

    Timer { id: phase; interval: 250; onTriggered: root.check() }
    Timer {
        id: late
        interval: 1200
        onTriggered: {
            if (root.finishedCount !== 1 || root.failedCount !== 0 || !root.same(root.received, ["status"]))
                return root.fail("busy: " + root.finishedCount + " finished, events " + JSON.stringify(root.received))
            if (call.busy) return root.fail("busy after finishing")
            if (!call.run(["--status"])) return root.fail("run() refused after finishing")
            again.start()
        }
    }
    Timer {
        id: again
        interval: 1200
        onTriggered: {
            if (root.finishedCount !== 2) return root.fail("second run finished " + root.finishedCount)
            console.log("PASS cli call contract")
            Qt.quit()
        }
    }
    Timer { interval: 25000; running: true; onTriggered: root.fail("timeout at scenario " + root.index) }
    Component.onCompleted: begin()
}
