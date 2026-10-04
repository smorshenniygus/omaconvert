import QtQuick
import QtQuick.Layouts
import "../services/Model.js" as Model

// Result summary: measured size change, output stats and Before/After
// thumbnails. Actions live in OmaConvert.qml so they can use the shell's
// qs.Ui buttons; this view stays dependency-free and unit-testable.
ColumnLayout {
    id: root
    required property var result
    property string sourcePreview: ""
    property string resultPreview: ""
    property bool sourceLoading: false
    property bool resultLoading: false
    property string savings: ""
    property string trimText: ""
    property string sourceMeta: ""
    property string resultMeta: ""
    property color foreground: "#cacccc"
    property color background: "#101315"
    property color accent: "#cacccc"
    property string fontFamily: "monospace"
    property int fontSize: 12
    property int radius: 0
    readonly property color dim: Qt.darker(foreground, 1.4)
    spacing: 12

    // Output file card: name + measured stats + savings pill.
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: fileInfo.implicitHeight + 24
        radius: root.radius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
        border.width: 1
        ColumnLayout {
            id: fileInfo
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 12
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: Model.name(root.result.path)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(root.fontSize * 1.083)
                    font.bold: true
                    elide: Text.ElideMiddle
                }
                Rectangle {
                    visible: root.savings !== ""
                    implicitWidth: savingsText.implicitWidth + 12
                    implicitHeight: savingsText.implicitHeight + 4
                    radius: root.radius
                    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.6)
                    border.width: 1
                    Text {
                        id: savingsText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: root.savings
                        color: root.accent
                        font.family: root.fontFamily
                        font.pixelSize: Math.round(root.fontSize * 0.917)
                        font.bold: true
                    }
                }
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: Model.megabytes(root.result.bytes) + "  ·  " + root.result.width + "×" + root.result.height
                      + (root.result.fps ? "  ·  " + Number(root.result.fps).toFixed(1) + " fps" : "")
                      + (root.result.colors ? "  ·  " + root.result.colors + " colors" : "")
                      + (root.result.frames ? "  ·  " + root.result.frames + " frames" : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Math.round(root.fontSize * 0.917)
                wrapMode: Text.WordWrap
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.trimText
                visible: root.trimText !== ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Math.round(root.fontSize * 0.917)
                wrapMode: Text.WordWrap
            }
        }
    }
    // Side by side on wide windows, stacked on narrow ones. Flow wraps
    // automatically once a child no longer fits next to its sibling.
    Flow {
        id: compareFlow
        Layout.fillWidth: true
        visible: root.sourcePreview !== "" || root.resultPreview !== ""
                 || root.sourceLoading || root.resultLoading
        spacing: 12
        PreviewImage {
            title: "Before"
            imageSource: root.sourcePreview
            loading: root.sourceLoading
            meta: root.sourceMeta
            foreground: root.foreground
            background: root.background
            fontFamily: root.fontFamily
            fontSize: root.fontSize
            radius: root.radius
            width: compareFlow.width >= 520 ? (compareFlow.width - compareFlow.spacing) / 2 : compareFlow.width
        }
        PreviewImage {
            title: "After"
            imageSource: root.resultPreview
            loading: root.resultLoading
            meta: root.resultMeta
            foreground: root.foreground
            background: root.background
            fontFamily: root.fontFamily
            fontSize: root.fontSize
            radius: root.radius
            width: compareFlow.width >= 520 ? (compareFlow.width - compareFlow.spacing) / 2 : compareFlow.width
        }
    }
}
