import QtQuick
import QtQuick.Layouts

// Checkbox row: square mark + label; Space or a click toggles.
Rectangle {
    id: check
    required property Theme theme
    property bool checked: false
    property string label: ""
    property string detail: ""
    signal toggled()
    Layout.fillWidth: true
    implicitHeight: checkRow.implicitHeight + 12
    color: checkMouse.containsMouse ? check.theme.surface : "transparent"
    activeFocusOnTab: true
    Accessible.role: Accessible.CheckBox
    Accessible.name: check.label
    Accessible.checked: check.checked
    Keys.onSpacePressed: check.toggled()
    Keys.onReturnPressed: check.toggled()
    Keys.onEnterPressed: check.toggled()
    RowLayout {
        id: checkRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 4
        spacing: 10
        Rectangle {
            Layout.preferredWidth: 12
            Layout.preferredHeight: 12
            color: check.checked ? check.theme.sage : "transparent"
            border.width: 1
            border.color: check.activeFocus ? check.theme.focus : (check.checked ? check.theme.sage : check.theme.alpha(check.theme.fg, 0.4))
        }
        MonoText {
            theme: check.theme
            text: check.label
            color: check.checked ? check.theme.fg : check.theme.dim
            font.bold: check.checked
        }
        MonoText {
            theme: check.theme
            visible: text !== ""
            text: check.detail
            color: check.theme.focus
            font.bold: true
        }
        Item { Layout.fillWidth: true }
    }
    MouseArea {
        id: checkMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { check.forceActiveFocus(); check.toggled() }
    }
}
