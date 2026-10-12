pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "../../services"
import "../ui"

// The command line: understands "gif 30mb", filters the recipes while you
// type and, with settings open, fills every field. Up/Down move through the
// recipes, Enter runs the highlighted one (or the fields), Esc clears the
// line. Below it, the words it understood.
ColumnLayout {
    id: root
    required property Theme theme
    required property Session session
    readonly property alias field: commandInput
    readonly property var metrics: Style.spacing
    signal pasteRequested()
    Layout.fillWidth: true
    spacing: 8
    function commandReturn(event) {
        // Ctrl+Enter belongs to the window shortcut.
        if (event.modifiers & Qt.ControlModifier) { event.accepted = false; return }
        event.accepted = true
        root.session.runActive()
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        LineEdit {
            id: commandInput
            Layout.fillWidth: true
            theme: root.theme
            leftPadding: root.metrics.controlPaddingX + root.theme.px(1.5)
            rightPadding: root.metrics.controlPaddingX
            verticalPadding: root.metrics.inputPaddingY
            fontSize: root.theme.px(1.167)
            bold: true
            maximumLength: 256
            placeholderText: root.session.inputKind === "image" ? "webp  ·  png 500kb  ·  jpg" : "gif 30mb  ·  mp4 quick  ·  png frames 10fps"
            Accessible.name: "What to make, for example gif 30mb"
            text: root.session.commandText
            onEdited: value => root.session.editCommand(value)
            Keys.onPressed: event => {
                if (event.matches(StandardKey.Paste)) { root.pasteRequested(); event.accepted = true }
            }
            Keys.onUpPressed: event => { root.session.moveSelection(-1); event.accepted = true }
            Keys.onDownPressed: event => { root.session.moveSelection(1); event.accepted = true }
            Keys.onReturnPressed: event => root.commandReturn(event)
            Keys.onEnterPressed: event => root.commandReturn(event)
            Keys.onEscapePressed: event => {
                if (commandInput.text === "") { event.accepted = false; return }
                root.session.editCommand("")
                event.accepted = true
            }
            Text {
                anchors.left: parent.left
                anchors.leftMargin: root.metrics.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: "❯"
                color: commandInput.activeFocus ? root.theme.focus : root.theme.faint
                font.family: root.theme.family
                font.pixelSize: root.theme.px(1.167)
                font.bold: true
            }
        }
        // Settings: full height of the line, square.
        Rectangle {
            id: settingsButton
            Layout.preferredWidth: commandInput.height
            Layout.preferredHeight: commandInput.height
            color: root.session.advanced ? root.theme.alpha(root.theme.focus, 0.2)
                 : (settingsMouse.containsMouse ? root.theme.alpha(root.theme.fg, 0.08) : root.theme.surface)
            border.width: 1
            border.color: root.session.advanced || settingsButton.activeFocus ? root.theme.focus : root.theme.alpha(root.theme.fg, 0.3)
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: root.session.advanced ? "Back to recipes" : "All settings"
            Keys.onReturnPressed: root.session.toggleAdvanced()
            Keys.onEnterPressed: root.session.toggleAdvanced()
            Keys.onSpacePressed: root.session.toggleAdvanced()
            Text {
                anchors.centerIn: parent
                text: root.session.advanced ? "󰅃" : "󰒓"
                color: root.session.advanced ? root.theme.focus : root.theme.fg
                font.family: root.theme.iconFamily
                font.pixelSize: root.theme.px(1.25)
            }
            MouseArea {
                id: settingsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.session.toggleAdvanced()
            }
            Ui.PanelToolTip {
                visible: settingsMouse.containsMouse
                text: root.session.advanced ? "Back to recipes  ·  Ctrl+," : "All settings  ·  Ctrl+,"
            }
        }
    }
    // Always one row tall: typing never pushes the list down.
    Flow {
        Layout.fillWidth: true
        spacing: 6
        MonoText {
            theme: root.theme
            size: 0.833
            text: root.session.matched.chips.length > 0 ? "understood"
                : (root.session.inputKind === "image" ? "type a format and size  ·  jpg 200kb  ·  webp" : "type a format and size  ·  gif 10mb  ·  mp4 quick")
            color: root.theme.faint
            height: 20
            verticalAlignment: Text.AlignVCenter
        }
        Repeater {
            model: root.session.matched.chips
            delegate: Rectangle {
                id: chip
                required property var modelData
                implicitWidth: chipText.implicitWidth + 14
                implicitHeight: 20
                color: chip.modelData.ok ? root.theme.alpha(root.theme.sage, 0.18) : "transparent"
                border.width: 1
                border.color: chip.modelData.ok ? root.theme.alpha(root.theme.sage, 0.56) : root.theme.line
                MonoText {
                    id: chipText
                    theme: root.theme
                    size: 0.833
                    anchors.centerIn: parent
                    text: chip.modelData.text
                    color: chip.modelData.ok ? root.theme.mist : root.theme.faint
                    font.strikeout: !chip.modelData.ok
                }
            }
        }
    }
}
