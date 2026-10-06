pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services/Model.js" as Model

// Result summary: the measured size big, whether it fits the limit, what
// changed, how much of the budget it used, and Before/After thumbnails.
// Actions live in OmaConvert.qml (keyboard shortcuts); this view stays
// dependency-free and unit-testable.
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
    property real sourceBytes: 0
    property real limitBytes: 0
    property color foreground: "#cacccc"
    property color background: "#101315"
    property color accent: "#819890"
    property color okColor: "#a5b5ab"
    property color limitColor: "#f4e276"
    property string fontFamily: "monospace"
    property int fontSize: 12
    property int radius: 0
    readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
    readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.32)
    readonly property var sizeParts: Model.megabytes(root.result.bytes).split(" ")
    readonly property bool fits: root.limitBytes > 0 && Number(root.result.bytes || 0) <= root.limitBytes
    spacing: 14

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: Model.name(root.result.path || "") + (root.result.kind === "sequence" ? "/" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 1.083)
            elide: Text.ElideMiddle
        }
        RowLayout {
            spacing: 10
            Text {
                textFormat: Text.PlainText
                text: root.sizeParts[0] || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Math.round(root.fontSize * 3.6)
                font.bold: true
            }
            Text {
                textFormat: Text.PlainText
                Layout.alignment: Qt.AlignBottom
                Layout.bottomMargin: 8
                text: root.sizeParts[1] || ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Math.round(root.fontSize * 1.333)
            }
            Rectangle {
                visible: root.fits || root.savings !== ""
                Layout.alignment: Qt.AlignBottom
                Layout.bottomMargin: 8
                implicitWidth: badge.implicitWidth + 16
                implicitHeight: badge.implicitHeight + 6
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
                border.width: 1
                border.color: root.accent
                Text {
                    id: badge
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.fits ? "✓ fits " + Model.sizeLabel(root.limitBytes) : root.savings
                    color: root.okColor
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(root.fontSize * 0.917)
                    font.bold: true
                }
            }
        }
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: [root.savings,
                   root.result.width ? root.result.width + "×" + root.result.height : "",
                   root.result.fps ? Number(root.result.fps).toFixed(1).replace(".0", "") + " fps" : "",
                   root.result.colors ? root.result.colors + " colors" : "",
                   root.result.frames ? root.result.frames + " frames" : "",
                   root.trimText].filter(part => part !== "").join("  ·  ")
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.fontSize * 0.833)
            wrapMode: Text.WordWrap
        }
    }
    SizeBudget {
        Layout.fillWidth: true
        visible: root.limitBytes > 0
        fromBytes: root.sourceBytes
        limitBytes: root.limitBytes
        resultBytes: Number(root.result.bytes || 0)
        foreground: root.foreground
        fillColor: root.accent
        limitColor: root.limitColor
        fontFamily: root.fontFamily
        fontSize: root.fontSize
    }
    // Side by side on wide windows, stacked on narrow ones. Flow wraps
    // automatically once a child no longer fits next to its sibling.
    Flow {
        id: compareFlow
        Layout.fillWidth: true
        visible: root.sourcePreview !== "" || root.resultPreview !== ""
                 || root.sourceLoading || root.resultLoading
        spacing: 18
        PreviewImage {
            title: "Before"
            imageSource: root.sourcePreview
            loading: root.sourceLoading
            meta: root.sourceMeta
            boxHeight: 144
            foreground: root.foreground
            background: root.background
            fontFamily: root.fontFamily
            fontSize: root.fontSize
            radius: root.radius
            width: compareFlow.width >= 460 ? (compareFlow.width - compareFlow.spacing) / 2 : compareFlow.width
        }
        PreviewImage {
            title: "After"
            imageSource: root.resultPreview
            loading: root.resultLoading
            meta: root.resultMeta
            boxHeight: 144
            foreground: root.foreground
            background: root.background
            fontFamily: root.fontFamily
            fontSize: root.fontSize
            radius: root.radius
            width: compareFlow.width >= 460 ? (compareFlow.width - compareFlow.spacing) / 2 : compareFlow.width
        }
    }
}
