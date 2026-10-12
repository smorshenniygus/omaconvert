pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../../services"
import "../../services/Model.js" as Model
import "../ui"

// Source: one big drop target while empty, then the file as a title with
// its facts underneath. Enter, Space or a click asks for the picker.
Item {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    property bool pickerBusy: false
    signal chooseRequested()
    visible: !root.service.result && root.session.screen !== "converting" && !root.service.isBatch
    Layout.fillWidth: true
    implicitHeight: root.service.inputPath ? sourceText.implicitHeight : emptyColumn.implicitHeight
    enabled: !root.service.busy && !root.pickerBusy
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: root.service.inputPath ? "Change source file" : "Choose a video or image"
    readonly property bool dragging: dropArea.containsDrag
    readonly property bool hot: chooseMouse.containsMouse || root.dragging
    Keys.onReturnPressed: root.chooseRequested()
    Keys.onEnterPressed: root.chooseRequested()
    Keys.onSpacePressed: root.chooseRequested()

    // Loaded: the file as a title, its facts underneath.
    RowLayout {
        id: sourceText
        visible: root.service.inputPath !== ""
        width: parent.width
        spacing: 12
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            SectionLabel { theme: root.theme; text: "SOURCE" }
            MonoText {
                theme: root.theme
                size: 1.5
                Layout.fillWidth: true
                text: root.dragging ? "Drop to open" : Model.name(root.service.inputPath)
                color: root.activeFocus ? root.theme.focus : root.theme.fg
                font.bold: true
                elide: Text.ElideMiddle
            }
            MonoText {
                theme: root.theme
                size: 0.917
                Layout.fillWidth: true
                text: root.service.metadata !== null ? Model.mediaDescription(root.service.metadata)
                    : (root.service.busy ? "Reading media…" : "Not read  ·  root another file")
                color: root.theme.dim
                elide: Text.ElideRight
            }
        }
        MonoText {
            theme: root.theme
            size: 0.917
            Layout.alignment: Qt.AlignBottom
            visible: !root.pickerBusy
            text: "change"
            color: root.hot ? root.theme.fg : root.theme.faint
        }
    }
    // Empty: one big drop target.
    ColumnLayout {
        id: emptyColumn
        visible: root.service.inputPath === ""
        width: parent.width
        spacing: 8
        SectionLabel { theme: root.theme; text: "SOURCE" }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 150
            color: root.dragging ? root.theme.alpha(root.theme.sage, 0.18)
                 : (root.hot ? root.theme.surface : "transparent")
            border.width: 1
            border.color: root.activeFocus || root.dragging ? root.theme.focus : root.theme.alpha(root.theme.fg, 0.3)
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 8
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.pickerBusy ? "󰔟" : "󰇚"
                    color: root.activeFocus ? root.theme.focus : root.theme.sage
                    font.family: root.theme.iconFamily
                    font.pixelSize: root.theme.px(2.333)
                }
                MonoText {
                    theme: root.theme
                    size: 1.167
                    Layout.alignment: Qt.AlignHCenter
                    text: root.pickerBusy ? "Choosing file…" : (root.dragging ? "Drop to open" : "Choose a video or image")
                    font.bold: true
                }
                MonoText {
                    theme: root.theme
                    size: 0.917
                    Layout.alignment: Qt.AlignHCenter
                    text: "⏎ browse  ·  drop a file  ·  ctrl+v paste"
                    color: root.theme.faint
                }
            }
        }
    }
    MouseArea {
        id: chooseMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.forceActiveFocus(); root.chooseRequested() }
    }
    DropArea {
        id: dropArea
        anchors.fill: parent
        onDropped: drop => {
            if (root.service.busy) return
            var paths = drop.urls.map(url => Model.localPath(url)).filter(path => !!path)
            if (paths.length) { root.service.selectFiles(paths); drop.acceptProposedAction() }
        }
    }
}
