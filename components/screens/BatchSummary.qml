pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../../services"
import "../../services/Model.js" as Model
import "../ui"

// Batch summary: the sizes before and after, what failed.
ColumnLayout {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    Layout.fillWidth: true
    visible: root.session.screen === "result" && root.service.isBatch
    spacing: 4
    RowLayout {
        spacing: 10
        MonoText {
            theme: root.theme
            size: 3.6
            text: root.service.result ? Model.compactSize(root.service.result.bytes_after) : ""
            font.bold: true
        }
        Rectangle {
            Layout.alignment: Qt.AlignBottom
            Layout.bottomMargin: 8
            implicitWidth: batchBadge.implicitWidth + 16
            implicitHeight: batchBadge.implicitHeight + 6
            color: root.theme.alpha(root.theme.sage, 0.22)
            border.width: 1
            border.color: root.theme.sage
            MonoText {
                id: batchBadge
                theme: root.theme
                size: 0.917
                anchors.centerIn: parent
                text: root.service.result ? "✓ " + root.service.result.done + " of " + root.service.result.total + " done" : ""
                color: root.theme.mist
                font.bold: true
            }
        }
    }
    MonoText {
        theme: root.theme
        size: 0.917
        Layout.fillWidth: true
        text: root.service.result ? Model.savingsText(root.service.result.bytes_before, root.service.result.bytes_after)
            + (root.service.result.failed ? "  ·  " + root.service.result.failed + " failed" : "") : ""
        color: root.service.result && root.service.result.failed ? root.theme.urgent : root.theme.faint
        wrapMode: Text.WordWrap
    }
}
