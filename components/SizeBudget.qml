pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "ui"
import "../services/Model.js" as Model

// Size budget: how a size compares with the limit. Before converting it
// reads "22.3 MB → ≤ 10 MB" with the share that has to go; after, the bar
// shows how much of the limit the result used. The limit marker sits at
// the limit's share of the larger of the two sizes. Without a limit (quick
// mode, frame sequences) it keeps its height and says so, so switching
// recipes never moves the layout.
ColumnLayout {
    id: root
    required property Theme theme
    property real fromBytes: 0
    property real limitBytes: 0
    // > 0 after converting: the measured result.
    property real resultBytes: 0
    readonly property bool done: root.resultBytes > 0
    readonly property real span: Math.max(root.fromBytes, root.limitBytes, root.resultBytes, 1)
    spacing: 6

    RowLayout {
        Layout.fillWidth: true
        visible: !root.done
        spacing: 8
        Text {
            textFormat: Text.PlainText
            text: Model.compactSize(root.fromBytes)
            color: root.theme.fg
            font.family: root.theme.family
            font.pixelSize: root.theme.px(1.333)
            font.bold: true
        }
        Text {
            textFormat: Text.PlainText
            text: "→"
            color: root.theme.alpha(root.theme.fg, 0.32)
            font.family: root.theme.family
            font.pixelSize: root.theme.px(1.167)
        }
        Text {
            textFormat: Text.PlainText
            text: root.limitBytes > 0 ? "≤ " + Model.sizeLabel(root.limitBytes) : "no size limit"
            color: root.limitBytes > 0 ? root.theme.focus : root.theme.alpha(root.theme.fg, 0.55)
            font.family: root.theme.family
            font.pixelSize: root.theme.px(1.333)
            font.bold: true
        }
        Item { Layout.fillWidth: true }
        Text {
            textFormat: Text.PlainText
            text: root.limitBytes <= 0 ? "quality preset"
                : (root.fromBytes > root.limitBytes
                   ? "−" + Math.ceil((1 - root.limitBytes / root.fromBytes) * 100) + "% to cut"
                   : "already fits")
            color: root.theme.alpha(root.theme.fg, 0.55)
            font.family: root.theme.family
            font.pixelSize: root.theme.px(0.917)
        }
    }
    Item {
        Layout.fillWidth: true
        implicitHeight: 14
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 8
            color: root.theme.alpha(root.theme.fg, 0.08)
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            height: 8
            width: root.limitBytes > 0 || root.done
                ? parent.width * Math.min(1, (root.done ? root.resultBytes : Math.min(root.fromBytes, root.limitBytes)) / root.span) : 0
            color: root.theme.sage
            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        }
        Rectangle {
            visible: root.limitBytes > 0
            anchors.verticalCenter: parent.verticalCenter
            x: Math.min(parent.width - width, parent.width * root.limitBytes / root.span)
            width: 2
            height: 14
            color: root.theme.focus
        }
    }
}
