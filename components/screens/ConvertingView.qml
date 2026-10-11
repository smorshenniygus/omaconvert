pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../../services"
import "../../services/Model.js" as Model
import "../ui"
import ".."

// Converting: the dimmed source, the phase, progress, every size the
// search measured against the limit, the elapsed time and cancel.
ColumnLayout {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    required property PreviewService preview
    property real clock: Date.now()
    visible: root.session.screen === "converting"
    Layout.fillWidth: true
    spacing: 16
    // Ticks the elapsed time.
    Timer {
        interval: 1000
        repeat: true
        running: root.service.busy
        onTriggered: root.clock = Date.now()
    }
    PreviewImage {
        Layout.fillWidth: true
        visible: !root.service.isBatch
        title: "Source"
        showHeader: false
        boxHeight: 200
        dimmed: 0.55
        imageSource: root.preview.sourceUrl
        loading: root.preview.sourceLoading
        theme: root.theme
    }
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        MonoText {
            theme: root.theme
            size: 0.917
            Layout.fillWidth: true
            text: (root.service.isBatch ? root.session.batchReady.length + " files" : Model.name(root.service.inputPath)) + "  →  " + root.session.jobCommand
            color: root.theme.dim
            elide: Text.ElideMiddle
        }
        MonoText {
            theme: root.theme
            size: 1.5
            Layout.fillWidth: true
            text: root.service.cancelling ? "Cancelling…"
                : root.service.isBatch ? "File " + Math.min(root.session.batchReady.length, root.session.batchFinished + 1) + " of " + root.session.batchReady.length
                : (root.service.phase.indexOf("Finding") === 0 ? "Finding the best quality that fits" : root.service.phase)
            font.bold: true
            wrapMode: Text.WordWrap
        }
    }
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            MonoText {
                theme: root.theme
                size: 0.917
                Layout.fillWidth: true
                text: root.service.isBatch ? (root.service.batchCurrent >= 0 ? Model.name(root.service.batch[root.service.batchCurrent].path) : "")
                    : root.service.currentPass ? "pass " + root.service.currentPass : (root.service.phase.indexOf("Finding") === 0 ? "analysing samples" : "")
                color: root.theme.mist
                font.bold: true
            }
            Text {
                visible: !progressTrack.indeterminate
                text: Math.round((root.service.isBatch ? root.session.batchProgress : root.service.progress) * 100) + "%"
                color: root.theme.fg
                font.family: root.theme.family
                font.pixelSize: root.theme.px(0.917)
                font.bold: true
            }
        }
        Rectangle {
            id: progressTrack
            readonly property bool indeterminate: !root.service.isBatch && root.service.phase.indexOf("Finding") === 0
            Layout.fillWidth: true
            implicitHeight: 6
            color: root.theme.alpha(root.theme.fg, 0.08)
            clip: true
            Rectangle {
                visible: !progressTrack.indeterminate
                height: parent.height
                color: root.theme.focus
                width: parent.width * Math.max(0, Math.min(1, root.service.isBatch ? root.session.batchProgress : root.service.progress))
                Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            }
            Rectangle {
                id: sweep
                visible: progressTrack.indeterminate
                height: parent.height
                color: root.theme.focus
                width: parent.width * 0.3
                NumberAnimation on x {
                    running: sweep.visible && root.service.busy
                    from: -sweep.width
                    to: progressTrack.width
                    duration: 1200
                    loops: Animation.Infinite
                    easing.type: Easing.InOutQuad
                }
            }
        }
    }
    // Every size the search measured, against the limit.
    ColumnLayout {
        id: candList
        Layout.fillWidth: true
        visible: root.service.candidates.length > 0
        spacing: 8
        readonly property real span: Math.max(root.session.jobLimitBytes * 1.39,
            Math.max.apply(null, root.service.candidates.map(c => c.estimated_bytes || 0)), 1)
        SectionLabel { theme: root.theme; text: "CANDIDATES" }
        Repeater {
            model: root.service.candidates
            delegate: ColumnLayout {
                id: cand
                required property var modelData
                readonly property real bytes: cand.modelData.estimated_bytes || 0
                readonly property bool fits: root.session.jobLimitBytes <= 0 || cand.bytes <= root.session.jobLimitBytes
                Layout.fillWidth: true
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    MonoText {
                        theme: root.theme
                        size: 0.917
                        Layout.fillWidth: true
                        text: cand.modelData.width + "×" + cand.modelData.height
                              + (cand.modelData.fps ? "  ·  " + Number(cand.modelData.fps).toFixed(1).replace(".0", "") + " fps" : "")
                              + (cand.modelData.colors ? "  ·  " + cand.modelData.colors + " col" : "")
                        elide: Text.ElideRight
                    }
                    MonoText {
                        theme: root.theme
                        size: 0.917
                        text: "≈ " + Model.compactSize(cand.bytes)
                        color: cand.fits ? root.theme.mist : root.theme.urgent
                        font.bold: true
                    }
                }
                Item {
                    Layout.fillWidth: true
                    implicitHeight: 10
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; color: root.theme.alpha(root.theme.fg, 0.06) }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        height: 4
                        width: parent.width * Math.min(1, cand.bytes / candList.span)
                        color: cand.fits ? root.theme.sage : root.theme.urgent
                    }
                    Rectangle {
                        visible: root.session.jobLimitBytes > 0
                        x: parent.width * root.session.jobLimitBytes / candList.span
                        width: 1
                        height: 10
                        color: root.theme.fg
                    }
                }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 6
        MonoText {
            theme: root.theme
            size: 0.917
            Layout.fillWidth: true
            text: Model.duration(Math.max(0, (root.clock - root.service.startedAt) / 1000)) + " elapsed"
            color: root.theme.faint
        }
        TextButton {
            theme: root.theme
            key: "esc"
            label: root.service.cancelling ? "cancelling…" : "cancel"
            enabled: !root.service.cancelling
            onClicked: root.service.cancel()
        }
    }
}
