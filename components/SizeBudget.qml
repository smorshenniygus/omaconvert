pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services/Model.js" as Model

// Size budget: how a size compares with the limit. Before converting it
// reads "22.3 MB → ≤ 10 MB" with the share that has to go; after, the bar
// shows how much of the limit the result used. The limit marker sits at
// the limit's share of the larger of the two sizes.
ColumnLayout {
    id: root
    property real fromBytes: 0
    property real limitBytes: 0
    // > 0 after converting: the measured result.
    property real resultBytes: 0
    property color foreground: "#cacccc"
    property color fillColor: "#819890"
    property color limitColor: "#f4e276"
    property string fontFamily: "monospace"
    property int fontSize: 12
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
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 1.333)
            font.bold: true
        }
        Text {
            textFormat: Text.PlainText
            text: "→"
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.32)
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 1.167)
        }
        Text {
            textFormat: Text.PlainText
            text: "≤ " + Model.sizeLabel(root.limitBytes)
            color: root.limitColor
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 1.333)
            font.bold: true
        }
        Item { Layout.fillWidth: true }
        Text {
            textFormat: Text.PlainText
            text: root.fromBytes > root.limitBytes
                ? "−" + Math.ceil((1 - root.limitBytes / root.fromBytes) * 100) + "% to cut"
                : "already fits"
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.917)
        }
    }
    Item {
        Layout.fillWidth: true
        implicitHeight: 14
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 8
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            height: 8
            width: parent.width * Math.min(1, (root.done ? root.resultBytes : Math.min(root.fromBytes, root.limitBytes)) / root.span)
            color: root.fillColor
            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        }
        Rectangle {
            visible: root.limitBytes > 0
            anchors.verticalCenter: parent.verticalCenter
            x: Math.min(parent.width - width, parent.width * root.limitBytes / root.span)
            width: 2
            height: 14
            color: root.limitColor
        }
    }
}
