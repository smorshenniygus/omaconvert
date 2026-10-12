import QtQuick

// Small bordered text button: "change", "×", "esc cancel".
Rectangle {
    id: tb
    required property Theme theme
    property string key: ""
    property string label: ""
    signal clicked()
    implicitWidth: tbRow.implicitWidth + 18
    implicitHeight: tbRow.implicitHeight + 8
    color: tbMouse.containsMouse ? tb.theme.alpha(tb.theme.fg, 0.06) : "transparent"
    border.width: 1
    border.color: tb.activeFocus ? tb.theme.focus : tb.theme.alpha(tb.theme.fg, 0.3)
    opacity: enabled ? 1 : 0.4
    activeFocusOnTab: enabled
    Accessible.role: Accessible.Button
    Accessible.name: tb.label
    Keys.onReturnPressed: tb.clicked()
    Keys.onEnterPressed: tb.clicked()
    Keys.onSpacePressed: tb.clicked()
    Row {
        id: tbRow
        anchors.centerIn: parent
        spacing: 6
        MonoText {
            theme: tb.theme
            size: 0.917
            visible: tb.key !== ""
            text: tb.key
            color: tb.theme.focus
            font.bold: true
        }
        MonoText {
            theme: tb.theme
            size: 0.917
            text: tb.label
        }
    }
    MouseArea {
        id: tbMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: tb.clicked()
    }
}
