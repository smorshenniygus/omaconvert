import QtQuick
import QtQuick.Layouts

// Compact bounded thumbnail with a checkerboard behind transparent pixels.
// The Image never loads the full-size source: PreviewService writes a
// max-320px PNG and this view displays only that file asynchronously.
// Theme values arrive as properties so the component stays dependency-free
// (unit-testable outside the shell); OmaConvert passes the live theme.
ColumnLayout {
    id: root
    required property string title
    property string imageSource: ""
    property bool loading: false
    property string meta: ""
    property color foreground: "#cacccc"
    property color background: "#101315"
    property color borderColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.3)
    property string fontFamily: "monospace"
    property int fontSize: 12
    property int radius: 0
    readonly property color dim: Qt.darker(foreground, 1.4)
    spacing: 6

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Text {
            textFormat: Text.PlainText
            text: root.title.toUpperCase()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.833)
            font.bold: true
            font.letterSpacing: 1.2
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
        Layout.fillWidth: true
        implicitHeight: 148
        radius: root.radius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
        border.color: root.borderColor
        border.width: 1
        clip: true
        // Subtle theme-tinted checkerboard for alpha, only behind the image.
        Canvas {
            id: checker
            anchors.centerIn: parent
            width: image.status === Image.Ready ? image.paintedWidth : 0
            height: image.status === Image.Ready ? image.paintedHeight : 0
            visible: root.imageSource !== "" && !root.loading && width > 0
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
            anchors.margins: 1
            source: root.imageSource
            asynchronous: true
            cache: false
            fillMode: Image.PreserveAspectFit
            sourceSize.width: 320
            sourceSize.height: 320
            visible: root.imageSource !== "" && !root.loading
            Accessible.name: root.title + " preview"
        }
        Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.loading ? "Loading preview…" : "No preview"
            visible: root.loading || root.imageSource === ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.917)
        }
    }
}
