import QtQuick
import Quickshell.Io
import "Model.js" as Model

// One small backend command at a time (status, toggles, paste): runs
// `python3 <executable> <args>` and hands every JSON event it prints to
// `event`. Independent of the conversion job queue in ConvertService.
Item {
    id: call
    required property string executable
    readonly property bool busy: process.running
    signal event(var event)

    function run(args) {
        if (process.running) return false
        process.command = ["python3", call.executable].concat(args)
        process.running = true
        return true
    }

    Process {
        id: process
        stdout: SplitParser {
            onRead: line => {
                var parsed = Model.eventFromLine(line)
                if (parsed) call.event(parsed)
            }
        }
    }
}
