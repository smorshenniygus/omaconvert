pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "ui"
import "../services/Model.js" as Model

// Result summary: the measured size big, whether it fits the limit, what
// changed, how much of the budget it used, and Before/After thumbnails.
// Actions live in OmaConvert.qml (keyboard shortcuts); this view stays
// dependency-free and unit-testable.
ColumnLayout {
    id: root
    required property Theme theme
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
    property int radius: 0
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
            color: root.theme.dim
            font.family: root.theme.family
            font.pixelSize: root.theme.px(1.083)
            elide: Text.ElideMiddle
        }
        RowLayout {
            spacing: 10
            Text {
                textFormat: Text.PlainText
                text: root.sizeParts[0] || ""
                color: root.theme.fg
                font.family: root.theme.family
                font.pixelSize: root.theme.px(3.6)
                font.bold: true
            }
            Text {
                textFormat: Text.PlainText
                Layout.alignment: Qt.AlignBottom
                Layout.bottomMargin: 8
                text: root.sizeParts[1] || ""
                color: root.theme.dim
                font.family: root.theme.family
                font.pixelSize: root.theme.px(1.333)
            }
            Rectangle {
                visible: root.fits || root.savings !== ""
                Layout.alignment: Qt.AlignBottom
                Layout.bottomMargin: 8
                implicitWidth: badge.implicitWidth + 16
                implicitHeight: badge.implicitHeight + 6
                color: root.theme.alpha(root.theme.sage, 0.22)
                border.width: 1
                border.color: root.theme.sage
                Text {
                    id: badge
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.fits ? "✓ fits " + Model.sizeLabel(root.limitBytes) : root.savings
                    color: root.theme.mist
                    font.family: root.theme.family
                    font.pixelSize: root.theme.px(0.917)
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
            color: root.theme.faint
            font.family: root.theme.family
            font.pixelSize: root.theme.px(0.833)
            wrapMode: Text.WordWrap
        }
    }
    SizeBudget {
        Layout.fillWidth: true
        visible: root.limitBytes > 0
        fromBytes: root.sourceBytes
        limitBytes: root.limitBytes
        resultBytes: Number(root.result.bytes || 0)
        theme: root.theme
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
            theme: root.theme
            radius: root.radius
            width: compareFlow.width >= 460 ? (compareFlow.width - compareFlow.spacing) / 2 : compareFlow.width
        }
        PreviewImage {
            title: "After"
            imageSource: root.resultPreview
            loading: root.resultLoading
            meta: root.resultMeta
            boxHeight: 144
            theme: root.theme
            radius: root.radius
            width: compareFlow.width >= 460 ? (compareFlow.width - compareFlow.spacing) / 2 : compareFlow.width
        }
    }
}
