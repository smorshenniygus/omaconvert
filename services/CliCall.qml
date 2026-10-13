import QtQuick
import Quickshell.Io
import "Model.js" as Model

// One small backend command at a time (status, toggles, paste): runs
// `<interpreter> <executable> <args>` and hands every JSON event it prints
// to `event`. Independent of the conversion job queue in ConvertService.
//
// Every accepted run() ends exactly once, whatever happens to the process:
// `failed(outcome)` (only when it failed) and then `finished(outcome)`, with
// `busy` already false so a handler may ask again (from a later turn of the
// event loop: the process object is still winding down inside the handler).
//
// outcome: {ok, reason, message, details, summary, exitCode, expected}
//   reason   "" when ok, otherwise
//            "start"       the process could not be started
//            "error"       the backend answered with an `error` event
//            "exit"        it exited with a nonzero status (or was killed)
//            "malformed"   it exited 0 without a readable answer, but printed
//                          something that was not an event
//            "no-response" it exited 0 without the `expect`ed event
//   message  one sentence for the user
//   details  what the backend said: its error details, or the tail of stderr
//   summary  message plus the last line of details, for a single line of text
//   exitCode -1 when the process never started
Item {
    id: call
    required property string executable
    // Replaced only by tests, to run a command whose interpreter is missing.
    property string interpreter: "python3"
    // The event that answers this call. A call that ends without it has
    // failed ("no-response" or "malformed"); without `expect` any clean exit
    // is a success.
    property string expect: ""
    readonly property bool busy: call.inFlight
    // The last settled call's outcome; null before the first.
    readonly property var outcome: call.lastOutcome
    signal event(var event)
    signal failed(var outcome)
    signal finished(var outcome)

    // Private: one run's state, cleared by run().
    property bool inFlight: false
    property var lastOutcome: null
    property bool didStart: false
    property bool answered: false
    property string badLine: ""
    property var errorEvent: null
    property var seenEvents: []
    property string stderrTail: ""

    function run(args) {
        // The old process also blocks a new run until it has fully ended.
        if (call.inFlight || process.running) return false
        call.inFlight = true
        call.didStart = false
        call.answered = false
        call.badLine = ""
        call.errorEvent = null
        call.seenEvents = []
        call.stderrTail = ""
        process.command = [call.interpreter, call.executable].concat(args)
        startup.restart()
        process.running = true
        return true
    }

    function receive(line) {
        if (!call.inFlight || !line.trim()) return
        var parsed = Model.eventFromLine(line)
        if (!parsed) {
            if (call.badLine === "") call.badLine = line.slice(0, 500)
            return
        }
        call.seenEvents = call.seenEvents.concat([parsed.event])
        if (call.expect !== "" && parsed.event === call.expect) call.answered = true
        if (parsed.event === "error" && call.errorEvent === null) call.errorEvent = parsed
        call.event(parsed)
    }

    function receiveError(line) {
        if (call.inFlight) call.stderrTail = (call.stderrTail + line + "\n").slice(-4000)
    }

    function fail(reason, message, details, exitCode) {
        var text = String(details || "").trim()
        var last = text.split("\n").pop()
        var failure = {
            ok: false, reason: reason, message: message, details: text, exitCode: exitCode,
            expected: call.expect,
            // A backend error already explains itself in its details.
            summary: reason === "error" ? (text || message) : (last ? message + " " + last : message)
        }
        call.settle(failure)
    }

    function conclude(exitCode) {
        if (call.errorEvent !== null)
            return call.fail("error", call.errorEvent.message || "The backend reported an error.",
                             call.errorEvent.details || "", exitCode)
        if (exitCode !== 0)
            return call.fail("exit", "The backend stopped unexpectedly (exit code " + exitCode + ").",
                             call.stderrTail || call.badLine, exitCode)
        if (call.expect !== "" && !call.answered) {
            if (call.badLine !== "")
                return call.fail("malformed", "The backend sent an answer the window could not read.",
                                 call.badLine, exitCode)
            return call.fail("no-response", "The backend finished without an answer.",
                             call.seenEvents.length
                                 ? "It sent " + call.seenEvents.join(", ") + " instead of " + call.expect + "."
                                 : call.stderrTail || "It printed nothing.", exitCode)
        }
        call.settle({ ok: true, reason: "", message: "", details: "", summary: "", exitCode: exitCode,
                      expected: call.expect })
    }

    function settle(result) {
        if (!call.inFlight) return
        call.inFlight = false
        startup.stop()
        call.lastOutcome = result
        if (!result.ok) call.failed(result)
        call.finished(result)
    }

    function startFailed() {
        if (!call.inFlight || call.didStart) return
        call.fail("start", "Could not start Python 3. Check that python3 and the plugin backend are installed.",
                  call.interpreter + " " + call.executable, -1)
    }

    Process {
        id: process
        stdout: SplitParser {
            onRead: line => call.receive(line)
        }
        stderr: SplitParser {
            onRead: line => call.receiveError(line)
        }
        onStarted: call.didStart = true
        // A command that cannot be started never exits: running just ends.
        onRunningChanged: { if (!running) call.startFailed() }
        // Installed Quickshell metadata omits QProcess::ExitStatus.
        // qmllint disable signal-handler-parameters
        // Quickshell ends both parsers (flushing a last line without a
        // newline) before it reports the exit, so every event is in by now.
        onExited: exitCode => { if (call.inFlight) call.conclude(exitCode) }
        // qmllint enable signal-handler-parameters
    }
    // The same check for a start failure that is reported late (or not at all).
    Timer {
        id: startup
        interval: 1500
        onTriggered: { if (!process.running) call.startFailed() }
    }
}
