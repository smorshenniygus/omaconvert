pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "ui"
import "../services/Model.js" as Model

// Trim timeline for videos with known duration, drawn like an edit track:
// a tick ruler, the kept range tinted in the selection color, square
// handles and a playhead at the frame the preview shows. The preview
// follows the handle being moved (debounced while dragging, immediate on
// release). Colours and type come from one Theme object, so the component
// stays dependency-free and unit-testable; OmaConvert passes the live theme.
ColumnLayout {
    id: root
    required property Theme theme
    required property real duration
    property real controlHeight: 36
    property real startTime: 0
    property real endTime: duration
    // Position of the frame the preview currently shows.
    property real playhead: 0
    readonly property bool valid: endTime - startTime >= 0.1
        && startTime >= 0 && (duration <= 0 || endTime <= duration + 0.001)
    // `draft`: the handle is still moving; a cheap nearby frame is enough.
    signal scrubRequested(real position, bool draft)

    readonly property real handleWidth: 6
    readonly property real trackHeight: Math.max(22, Math.round(root.controlHeight * 0.72))

    function reset() {
        scrubTimer.stop()
        draftTimer.stop()
        pendingScrub = -1
        activeHandle = "first"
        startTime = 0
        endTime = root.duration
        playhead = 0
    }
    function setRange(start, end) {
        var clamped = Math.max(0, Math.min(root.duration, end))
        startTime = Math.max(0, Math.min(start, clamped - 0.1))
        endTime = clamped
    }
    // Last moved position waiting for the debounce; -1 means idle.
    property real pendingScrub: -1
    // Which handle arrows drive; updated by press and release.
    property string activeHandle: "first"
    // While a handle moves, a draft frame at most every 250 ms; the exact
    // frame once it rests for 600 ms (keyboard) or on release (scrubNow).
    function noteMove(position) {
        pendingScrub = position
        draftPending = true
        if (!draftTimer.running) draftTimer.start()
        scrubTimer.restart()
    }
    function scrubNow(position) {
        scrubTimer.stop()
        draftTimer.stop()
        pendingScrub = -1
        draftPending = false
        playhead = position
        root.scrubRequested(position, false)
    }
    property bool draftPending: false

    Timer {
        id: draftTimer
        interval: 250
        onTriggered: {
            if (root.draftPending && root.pendingScrub >= 0) {
                root.draftPending = false
                root.scrubRequested(root.pendingScrub, true)
            }
        }
    }
    Timer {
        id: scrubTimer
        interval: 600
        onTriggered: {
            if (root.pendingScrub >= 0) {
                var position = root.pendingScrub
                root.pendingScrub = -1
                root.draftPending = false
                draftTimer.stop()
                root.playhead = position
                root.scrubRequested(position, false)
            }
        }
    }

    spacing: 6
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Text {
            textFormat: Text.PlainText
            text: "IN " + Model.timeText(root.startTime)
            color: root.theme.mist
            font.family: root.theme.family
            font.pixelSize: root.theme.px(0.917)
            font.bold: true
        }
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: Number(Math.max(0, root.endTime - root.startTime)).toFixed(1) + " s of "
                  + Number(root.duration).toFixed(1) + " s"
            color: root.theme.dim
            font.family: root.theme.family
            font.pixelSize: root.theme.px(0.917)
            elide: Text.ElideRight
        }
        Text {
            textFormat: Text.PlainText
            text: "OUT " + Model.timeText(root.endTime)
            color: root.theme.mist
            font.family: root.theme.family
            font.pixelSize: root.theme.px(0.917)
            font.bold: true
        }
    }
    Item {
        id: slider
        Layout.fillWidth: true
        implicitHeight: root.trackHeight + 8
        activeFocusOnTab: true
        Accessible.name: "Trim interval"
        Accessible.description: "Left and right arrows move the active trim handle"

        readonly property real span: Math.max(0.0001, root.duration)
        readonly property real radius: root.handleWidth / 2
        readonly property real trackWidth: Math.max(1, slider.width - 2 * slider.radius)
        function valueFromX(x) {
            var clamped = Math.max(0, Math.min(slider.trackWidth, x - slider.radius))
            return clamped / slider.trackWidth * slider.span
        }
        function xFromValue(value) {
            return slider.radius + Math.max(0, Math.min(1, value / slider.span)) * slider.trackWidth
        }
        function nearestHandle(x) {
            var firstX = slider.xFromValue(root.startTime)
            var secondX = slider.xFromValue(root.endTime)
            return Math.abs(x - firstX) <= Math.abs(x - secondX) ? "first" : "second"
        }
        function moveActive(value) {
            if (root.activeHandle === "first") {
                root.startTime = Math.max(0, Math.min(value, root.endTime - 0.1))
                root.noteMove(root.startTime)
            } else {
                root.endTime = Math.min(root.duration, Math.max(value, root.startTime + 0.1))
                root.noteMove(root.endTime)
            }
        }

        Keys.onLeftPressed: (event) => { slider.moveActive((root.activeHandle === "first" ? root.startTime : root.endTime) - 0.5); event.accepted = true }
        Keys.onRightPressed: (event) => { slider.moveActive((root.activeHandle === "first" ? root.startTime : root.endTime) + 0.5); event.accepted = true }

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            x: slider.radius
            width: slider.trackWidth
            height: root.trackHeight
            color: root.theme.surface
            border.width: 1
            border.color: slider.activeFocus ? root.theme.focus : root.theme.line
            // Ruler: a tick every 10 px, a taller one every fifth.
            Repeater {
                model: Math.max(0, Math.floor((track.width - 8) / 10))
                delegate: Rectangle {
                    required property int index
                    x: 4 + index * 10
                    width: 1
                    height: index % 5 === 0 ? track.height * 0.46 : track.height * 0.24
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.theme.alpha(root.theme.fg, 0.14)
                }
            }
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            height: root.trackHeight
            x: slider.xFromValue(root.startTime)
            width: Math.max(1, slider.xFromValue(root.endTime) - x)
            color: root.theme.alpha(root.theme.sage, 0.22)
            border.width: 1
            border.color: root.theme.sage
        }
        Rectangle {
            visible: root.playhead > root.startTime && root.playhead < root.endTime
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: root.trackHeight + 6
            x: slider.xFromValue(root.playhead)
            color: root.theme.focus
        }
        // Square handles, taller than the track; the active one glows.
        Repeater {
            model: ["first", "second"]
            delegate: Rectangle {
                id: handle
                required property string modelData
                readonly property bool active: drag.dragged === handle.modelData
                    || (slider.activeFocus && root.activeHandle === handle.modelData)
                width: root.handleWidth
                height: root.trackHeight + 8
                anchors.verticalCenter: parent.verticalCenter
                x: slider.xFromValue(handle.modelData === "first" ? root.startTime : root.endTime) - width / 2
                color: handle.active ? root.theme.focus : root.theme.fg
            }
        }
        MouseArea {
            id: drag
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SizeHorCursor
            preventStealing: true
            property string dragged: ""
            onPressed: function(mouse) {
                slider.focus = true
                root.activeHandle = slider.nearestHandle(mouse.x)
                dragged = root.activeHandle
                slider.moveActive(slider.valueFromX(mouse.x))
            }
            onPositionChanged: function(mouse) {
                if (!dragged) return
                root.activeHandle = dragged
                slider.moveActive(slider.valueFromX(mouse.x))
            }
            onReleased: {
                if (!dragged) return
                var value = dragged === "first" ? root.startTime : root.endTime
                dragged = ""
                root.scrubNow(value)
            }
        }
    }
    Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: !root.valid
        text: "Pick an interval of at least 0.1 seconds."
        color: root.theme.urgent
        font.family: root.theme.family
        font.pixelSize: root.theme.px(0.917)
        wrapMode: Text.WordWrap
    }
}
