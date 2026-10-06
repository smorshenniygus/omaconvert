pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services/Model.js" as Model

// Trim timeline for videos with known duration, drawn like an edit track:
// a tick ruler, the kept range tinted in the selection color, square
// handles and a playhead at the frame the preview shows. The preview
// follows the handle being moved (debounced while dragging, immediate on
// release). Theme colors arrive as properties so the component stays
// dependency-free and unit-testable; OmaConvert passes the live theme.
ColumnLayout {
    id: root
    required property real duration
    property color trackColor: "#0af8ebe3"
    property color fillColor: "#819890"
    property color knobColor: "#e8e8e8"
    property color knobBorderColor: "#101315"
    property color lineColor: "#3a4849"
    property color playheadColor: "#f4e276"
    property color labelColor: "#a5b5ab"
    property real controlHeight: 36
    property color textColor: "#cacccc"
    property color urgentColor: "#a55555"
    property string fontFamily: "monospace"
    property int fontSize: 12
    readonly property color dimColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.55)
    property real startTime: 0
    property real endTime: duration
    // Position of the frame the preview currently shows.
    property real playhead: 0
    readonly property bool valid: endTime - startTime >= 0.1
        && startTime >= 0 && (duration <= 0 || endTime <= duration + 0.001)
    signal scrubRequested(real position)

    readonly property real handleWidth: 6
    readonly property real trackHeight: Math.max(22, Math.round(root.controlHeight * 0.72))

    function reset() {
        scrubTimer.stop()
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
    function noteMove(position) {
        pendingScrub = position
        scrubTimer.restart()
    }
    function scrubNow(position) {
        scrubTimer.stop()
        pendingScrub = -1
        playhead = position
        root.scrubRequested(position)
    }

    Timer {
        id: scrubTimer
        interval: 600
        onTriggered: {
            if (root.pendingScrub >= 0) {
                var position = root.pendingScrub
                root.pendingScrub = -1
                root.playhead = position
                root.scrubRequested(position)
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
            color: root.labelColor
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.917)
            font.bold: true
        }
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: Number(Math.max(0, root.endTime - root.startTime)).toFixed(1) + " s of "
                  + Number(root.duration).toFixed(1) + " s"
            color: root.dimColor
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.917)
            elide: Text.ElideRight
        }
        Text {
            textFormat: Text.PlainText
            text: "OUT " + Model.timeText(root.endTime)
            color: root.labelColor
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.917)
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
            color: root.trackColor
            border.width: 1
            border.color: slider.activeFocus ? root.playheadColor : root.lineColor
            // Ruler: a tick every 10 px, a taller one every fifth.
            Repeater {
                model: Math.max(0, Math.floor((track.width - 8) / 10))
                delegate: Rectangle {
                    required property int index
                    x: 4 + index * 10
                    width: 1
                    height: index % 5 === 0 ? track.height * 0.46 : track.height * 0.24
                    anchors.verticalCenter: parent.verticalCenter
                    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.14)
                }
            }
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            height: root.trackHeight
            x: slider.xFromValue(root.startTime)
            width: Math.max(1, slider.xFromValue(root.endTime) - x)
            color: Qt.rgba(root.fillColor.r, root.fillColor.g, root.fillColor.b, 0.22)
            border.width: 1
            border.color: root.fillColor
        }
        Rectangle {
            visible: root.playhead > root.startTime && root.playhead < root.endTime
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: root.trackHeight + 6
            x: slider.xFromValue(root.playhead)
            color: root.playheadColor
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
                color: handle.active ? root.playheadColor : root.knobColor
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
        color: root.urgentColor
        font.family: root.fontFamily
        font.pixelSize: Math.round(root.fontSize * 0.917)
        wrapMode: Text.WordWrap
    }
}
