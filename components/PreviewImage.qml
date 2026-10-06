pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// Bounded thumbnail with a checkerboard behind transparent pixels and
// optional chips over the frame (timecode bottom-left, badge top-right).
// The Image never loads the full-size source: PreviewService writes a
// max-320px PNG and this view displays only that file asynchronously.
// While a new frame loads the previous one stays on screen, so dragging a
// trim handle never flashes an empty box. Theme values arrive as
// properties so the component stays dependency-free (unit-testable).
ColumnLayout {
    id: root
    required property string title
    property string imageSource: ""
    property bool loading: false
    property string meta: ""
    property bool showHeader: true
    property string overlayText: ""
    property color overlayDot: "transparent"
    property string badgeText: ""
    property real boxHeight: 148
    property real dimmed: 1.0
    property color foreground: "#cacccc"
    property color background: "#101315"
    property color borderColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.16)
    property string fontFamily: "monospace"
    property int fontSize: 12
    property int radius: 0
    readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
    readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.32)
    readonly property bool hasFrame: image.status === Image.Ready && root.imageSource !== ""
    spacing: 6

    RowLayout {
        Layout.fillWidth: true
        visible: root.showHeader
        spacing: 8
        Text {
            textFormat: Text.PlainText
            text: root.title.toUpperCase()
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.833)
            font.bold: true
            font.letterSpacing: 2
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
        Text {
            textFormat: Text.PlainText
            text: root.meta
            visible: root.meta !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.833)
        }
    }
    Rectangle {
        id: box
        Layout.fillWidth: true
        implicitHeight: root.boxHeight
        radius: root.radius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
        border.color: root.borderColor
        border.width: 1
        clip: true
        Item {
            anchors.fill: parent
            anchors.margins: 1
            // Subtle theme-tinted checkerboard for alpha, only behind the image.
            Canvas {
                id: checker
                anchors.centerIn: parent
                width: root.hasFrame ? image.paintedWidth : 0
                height: root.hasFrame ? image.paintedHeight : 0
                visible: width > 0
                property color light: Qt.tint(root.background, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16))
                property color dark: Qt.tint(root.background, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08))
                onPaint: {
                    var ctx = getContext("2d")
                    var step = 8
                    ctx.reset()
                    ctx.fillStyle = dark
                    ctx.fillRect(0, 0, width, height)
                    ctx.fillStyle = light
                    for (var y = 0; y < height; y += step) {
                        for (var x = 0; x < width; x += step) {
                            if (((x / step) + (y / step)) % 2 === 0)
                                ctx.fillRect(x, y, step, step)
                        }
                    }
                }
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onLightChanged: requestPaint()
            }
            Image {
                id: image
                anchors.fill: parent
                source: root.imageSource
                asynchronous: true
                cache: false
                retainWhileLoading: true
                fillMode: Image.PreserveAspectFit
                sourceSize.width: 320
                sourceSize.height: 320
                visible: root.hasFrame
                Accessible.name: root.title + " preview"
            }
        }
        // Dimmed while converting: a veil, so the checkerboard stays hidden.
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            visible: root.dimmed < 1
            color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1 - root.dimmed)
        }
        Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.loading ? "Loading preview…" : "No preview"
            visible: !root.hasFrame
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.917)
        }
        Chip {
            visible: root.overlayText !== ""
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 10
            text: root.overlayText
            dot: root.overlayDot
            bold: true
        }
        Chip {
            visible: root.badgeText !== ""
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 10
            text: root.badgeText
            textColor: root.dim
        }
    }

    component Chip: Rectangle {
        id: chip
        property string text: ""
        property color dot: "transparent"
        property color textColor: root.foreground
        property bool bold: false
        implicitWidth: chipRow.implicitWidth + 16
        implicitHeight: chipRow.implicitHeight + 6
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.8)
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6
            Rectangle {
                visible: chip.dot.a > 0
                width: 6
                height: 6
                radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: chip.dot
            }
            Text {
                textFormat: Text.PlainText
                text: chip.text
                color: chip.textColor
                font.family: root.fontFamily
                font.pixelSize: Math.round(root.fontSize * 0.917)
                font.bold: chip.bold
            }
        }
    }
}
