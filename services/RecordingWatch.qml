pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// The end of an Omarchy screen recording. While it records, Omarchy keeps
// the recording's file name in a marker file and removes the marker once
// the video is finalized: the marker going away is the end.
//
// The shell never reads the marker itself. Every two seconds `find` checks
// each candidate path without following links (a regular file, owned by
// this user, at most 4 KiB) and only then `head` prints at most 4 KiB of
// it, in their own processes. A file another account planted, a link, a
// pipe or a huge sparse file is skipped without being read.
Item {
    id: root
    // False stops the polling (the user turned the offer off).
    property bool watching: true
    // Omarchy's own marker: in the private runtime folder since Omarchy
    // moved it out of /tmp, at the shared /tmp name in 4.0.4 and older.
    readonly property string runtimeFolder: Quickshell.env("XDG_RUNTIME_DIR")
        || ((Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy")
    property var markers: Quickshell.env("OMACONVERT_RECORDING_MARKER")
        ? [Quickshell.env("OMACONVERT_RECORDING_MARKER")]
        : [root.runtimeFolder + "/omarchy-screenrecord-filename", "/tmp/omarchy-screenrecord-filename"]
    property int interval: 2000
    // The file being recorded right now, "" when none.
    property string activeRecording: ""
    property string uid: ""
    signal ended(string file)

    function seen(text) {
        var name = String(text || "").split("\n").map(line => line.trim()).filter(line => line !== "")[0] || ""
        if (name) {
            root.activeRecording = name
        } else if (root.activeRecording) {
            const file = root.activeRecording
            root.activeRecording = ""
            root.ended(file)
        }
    }

    Process {
        id: whoami
        command: ["id", "-u"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: { var id = text.trim(); if (/^[0-9]+$/.test(id)) root.uid = id }
        }
    }
    Process {
        id: probe
        // Set when a stuck read is stopped: its partial output is ignored.
        property bool stale: false
        command: ["find"].concat(root.markers).concat(["-maxdepth", "0", "-type", "f", "-user", root.uid,
                  "-size", "-4097c", "-exec", "head", "-c", "4096", "--", "{}", ";"])
        stdout: StdioCollector { onStreamFinished: if (!probe.stale) root.seen(text) }
        // Missing paths are the normal case; their messages are not wanted.
        stderr: StdioCollector {}
    }
    Timer {
        interval: root.interval
        repeat: true
        running: root.watching && root.uid !== ""
        // A read still running two seconds later is stuck (a pipe swapped
        // in after the check): stop it and try again next time.
        onTriggered: {
            if (probe.running) {
                probe.stale = true
                probe.running = false
                return
            }
            probe.stale = false
            probe.running = true
        }
    }
}
