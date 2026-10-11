pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../../services"
import "../../services/Model.js" as Model
import "../ui"

// Batch: every file with its state, the totals and what each file becomes.
ColumnLayout {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    signal chooseRequested()
    Layout.fillWidth: true
    visible: root.service.isBatch
    spacing: 6
    RowLayout {
        Layout.fillWidth: true
        SectionLabel { theme: root.theme; text: "BATCH"; Layout.fillWidth: true }
        MonoText {
            theme: root.theme
            size: 0.917
            visible: !root.service.busy && !root.service.result
            text: "change"
            color: batchChange.containsMouse ? root.theme.fg : root.theme.faint
            MouseArea {
                id: batchChange
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.chooseRequested()
            }
        }
    }
    MonoText {
        theme: root.theme
        size: 1.5
        Layout.fillWidth: true
        text: root.session.batchReady.length ? root.session.batchTitle()
            : (root.service.busy ? "Reading " + root.service.batch.length + " files…" : "None of these files can be read")
        font.bold: true
    }
    MonoText {
        theme: root.theme
        size: 0.917
        Layout.fillWidth: true
        // Always one line tall, so recipes do not move.
        text: (root.session.idleWithFile ? "each file  →  " + (root.session.activeLimit > 0 ? "≤ " + Model.sizeLabel(root.session.activeLimit) : "quality preset") : "")
            + (root.session.batchNote() ? (root.session.idleWithFile ? "  ·  " : "") + root.session.batchNote() : "") || " "
        color: root.theme.dim
        elide: Text.ElideRight
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: Math.min(batchRows.implicitHeight, 8 * 30) + 2
        color: "transparent"
        border.width: 1
        border.color: root.theme.line
        clip: true
        Flickable {
            id: batchFlick
            anchors.fill: parent
            anchors.margins: 1
            contentHeight: batchRows.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            // Keep the file being converted in view.
            contentY: root.service.batchCurrent < 0 ? contentY
                : Math.max(0, Math.min(contentHeight - height, root.service.batchCurrent * 30 - height / 2))
            Behavior on contentY { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Column {
                id: batchRows
                width: batchFlick.width
                Repeater {
                    model: root.service.batchModel
                    delegate: Rectangle {
                        id: batchRow
                        required property string path
                        required property string status
                        required property bool ok
                        required property real bytes
                        required property real outputBytes
                        required property string message
                        readonly property string phaseName: batchRow.status || "reading"
                        width: batchRows.width
                        height: 30
                        color: batchRow.phaseName === "working" ? root.theme.alpha(root.theme.focus, 0.08) : "transparent"
                        Rectangle { visible: batchRow.phaseName === "working"; width: 2; height: parent.height; color: root.theme.focus }
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.theme.alpha(root.theme.fg, 0.06) }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 10
                            MonoText {
                                theme: root.theme
                                Layout.preferredWidth: root.theme.px(1)
                                text: ({ reading: "…", queued: "·", working: "▸", done: "✓", failed: "✗", skipped: "–", stopped: "■" })[batchRow.phaseName] || "·"
                                color: batchRow.phaseName === "done" ? root.theme.mist : (batchRow.phaseName === "failed" ? root.theme.urgent
                                     : (batchRow.phaseName === "working" ? root.theme.focus : root.theme.faint))
                                font.bold: true
                            }
                            MonoText {
                                theme: root.theme
                                size: 0.917
                                Layout.fillWidth: true
                                text: Model.name(batchRow.path)
                                color: batchRow.phaseName === "skipped" || batchRow.phaseName === "failed" && !batchRow.ok ? root.theme.faint : root.theme.fg
                                elide: Text.ElideMiddle
                            }
                            MonoText {
                                theme: root.theme
                                size: 0.833
                                Layout.maximumWidth: batchRows.width * 0.48
                                text: batchRow.phaseName === "working" ? Math.round(root.service.progress * 100) + "%"
                                    : batchRow.phaseName === "done" ? Model.compactSize(batchRow.bytes) + "  →  " + Model.compactSize(batchRow.outputBytes)
                                    : batchRow.phaseName === "failed" || batchRow.phaseName === "skipped" ? (batchRow.message || batchRow.phaseName)
                                    : batchRow.phaseName === "stopped" ? "stopped"
                                    : batchRow.phaseName === "reading" ? "reading…"
                                    : Model.compactSize(batchRow.bytes)
                                color: batchRow.phaseName === "failed" ? root.theme.urgent : (batchRow.phaseName === "done" ? root.theme.mist : root.theme.dim)
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}
