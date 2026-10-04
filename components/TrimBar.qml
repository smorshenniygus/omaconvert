import QtQuick
import QtQuick.Layouts
import "../services/Model.js" as Model

// Trim timeline for videos with known duration (DEV-05), drawn in the
// Omarchy idiom (cf. shell Ui/PanelSlider): thin track, round knobs,
// full-area mouse handling. The frame preview follows the handle being
// moved (debounced while dragging, immediate on release).
// Theme colors arrive as properties so the component stays dependency-free
// and unit-testable outside the shell; OmaConvert passes the live theme.
// Hidden for images and unknown durations; the backend rejects those.
ColumnLayout {
    id: root
    required property real duration
    property color trackColor: "#333333"
    property color fillColor: "#e8e8e8"
    property color knobColor: "#e8e8e8"
    property color knobBorderColor: "#101315"
    property real controlHeight: 36
    property color textColor: "#cacccc"
    property color urgentColor: "#a55555"
    property string fontFamily: "monospace"
    property int fontSize: 12
    readonly property color dimColor: Qt.darker(textColor, 1.4)
    property real startTime: 0
    property real endTime: duration
    readonly property bool valid: endTime - startTime >= 0.1
        && startTime >= 0 && (duration <= 0 || endTime <= duration + 0.001)
    signal scrubRequested(real position)

    readonly property real knobSize: Math.max(16, Math.round(root.controlHeight * 0.42))
    readonly property real trackHeight: Math.max(4, Math.round(root.controlHeight * 0.11))

    function reset() {
        scrubTimer.stop()
        pendingScrub = -1
        activeHandle = "first"
        startTime = 0
        endTime = root.duration
    }
    function setRange(start, end) {
        var clamped = Math.max(0, Math.min(root.duration, end))
        startTime = Math.max(0, Math.min(start, clamped - 0.1))
        endTime = clamped
    }
    // Last moved position waiting for the debounce; -1 means idle.
    property real pendingScrub: -1
    // Which handle arrows/wheel drive; updated by press and release.
    property string activeHandle: "first"
    function noteMove(position) {
        pendingScrub = position
        scrubTimer.restart()
    }
    function scrubNow(position) {
        scrubTimer.stop()
        pendingScrub = -1
        root.scrubRequested(position)
    }

    Timer {
        id: scrubTimer
        interval: 600
        onTriggered: {
            if (root.pendingScrub >= 0) {
                var position = root.pendingScrub
                root.pendingScrub = -1
                root.scrubRequested(position)
            }
        }
    }

    spacing: 4
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Text {
            textFormat: Text.PlainText
            text: "TRIM"
            color: root.dimColor
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.833)
            font.bold: true
            font.letterSpacing: 1.2
            Layout.fillWidth: true
        }
        Text {
            textFormat: Text.PlainText
            text: Model.timeText(root.startTime) + " – " + Model.timeText(root.endTime)
                  + "  /  " + Model.timeText(root.duration)
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.917)
        }
    }
    Item {
        id: slider
        Layout.fillWidth: true
        implicitHeight: Math.max(root.controlHeight, root.knobSize + 8)
        activeFocusOnTab: true
        Accessible.name: "Trim interval"
        Accessible.description: "Left and right arrows move the active trim handle"

        readonly property real span: Math.max(0.0001, root.duration)
        readonly property real radius: root.knobSize / 2
        function valueFromX(x) {
            var track = slider.width - 2 * slider.radius
            var clamped = Math.max(0, Math.min(track, x - slider.radius))
            return clamped / track * slider.span
        }
        function xFromValue(value) {
            var track = slider.width - 2 * slider.radius
            return slider.radius + Math.max(0, Math.min(1, value / slider.span)) * track
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
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: slider.radius
            anchors.rightMargin: slider.radius
            height: root.trackHeight
            radius: height / 2
            color: root.trackColor
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            height: root.trackHeight
            radius: height / 2
            color: root.fillColor
            x: slider.xFromValue(root.startTime)
            width: Math.max(height, slider.xFromValue(root.endTime) - x)
        }
        // Round knobs in the Omarchy idiom; the whole slider area grabs.
        Rectangle {
            id: knobFirst
            width: root.knobSize
            height: root.knobSize
            radius: root.knobSize / 2
            color: root.knobColor
            border.width: 2
            border.color: root.knobBorderColor
            anchors.verticalCenter: parent.verticalCenter
            x: slider.xFromValue(root.startTime) - width / 2
            scale: drag.dragged === "first" ? 1.15 : 1.0
            Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        }
        Rectangle {
            id: knobSecond
            width: root.knobSize
            height: root.knobSize
            radius: root.knobSize / 2
            color: root.knobColor
            border.width: 2
            border.color: root.knobBorderColor
            anchors.verticalCenter: parent.verticalCenter
            x: slider.xFromValue(root.endTime) - width / 2
            scale: drag.dragged === "second" ? 1.15 : 1.0
            Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        }
        MouseArea {
            id: drag
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
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
    Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: "Size limit and quality apply to the trimmed part."
        color: root.dimColor
        font.family: root.fontFamily
        font.pixelSize: Math.round(root.fontSize * 0.833)
        wrapMode: Text.WordWrap
    }
}
