import QtQuick
import Quickshell
import Quickshell.Io
import "../../services" as Services

// The recording watch reads Omarchy's marker only when it is the user's own
// small regular file: a link, a pipe or a huge sparse file is skipped, and
// the marker going away reports the end of that recording.
ShellRoot {
    id: root
    readonly property string folder: Quickshell.env("MARKER_DIR")
    property var endedFiles: []
    property int step: 0
    property real at: 0
    Services.RecordingWatch {
        id: watch
        interval: 100
        markers: [root.folder + "/marker"]
        onEnded: file => root.endedFiles = root.endedFiles.concat([file])
    }
    Process { id: sh }
    function run(script) { sh.command = ["sh", "-c", script, "sh", root.folder]; sh.running = true }
    function fail(message) { console.error("FAIL " + message); Qt.quit() }
    Timer { interval: 15000; running: true; onTriggered: root.fail("timeout at step " + root.step) }
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            var since = Date.now() - root.at
            switch (root.step) {
            case 0: if (watch.uid === "") return
                root.run('printf "%s\\n" "/home/u/Videos/rec.mp4" > "$1/marker"'); root.at = Date.now(); root.step++; return
            case 1: if (watch.activeRecording !== "/home/u/Videos/rec.mp4") { if (since > 3000) root.fail("own marker not read"); return }
                root.run('rm "$1/marker"'); root.at = Date.now(); root.step++; return
            case 2: if (root.endedFiles.length !== 1) { if (since > 3000) root.fail("end not reported"); return }
                if (root.endedFiles[0] !== "/home/u/Videos/rec.mp4" || watch.activeRecording !== "") return root.fail("wrong end " + root.endedFiles)
                // a huge sparse file, a link to a real marker and a pipe
                root.run('truncate -s 2G "$1/marker"'); root.at = Date.now(); root.step++; return
            case 3: if (since < 600) return
                if (watch.activeRecording !== "") return root.fail("sparse file was read")
                root.run('rm "$1/marker"; printf "x\\n" > "$1/real"; ln -s "$1/real" "$1/marker"'); root.at = Date.now(); root.step++; return
            case 4: if (since < 600) return
                if (watch.activeRecording !== "") return root.fail("link was followed")
                root.run('rm "$1/marker"; mkfifo "$1/marker"'); root.at = Date.now(); root.step++; return
            case 5: if (since < 600) return
                if (watch.activeRecording !== "" || root.endedFiles.length !== 1) return root.fail("pipe was read")
                console.log("PASS recording watch reads only a small own marker")
                Qt.quit()
            }
        }
    }
}
