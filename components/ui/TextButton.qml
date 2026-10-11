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
        Text {
            visible: tb.key !== ""
            textFormat: Text.PlainText
            text: tb.key
            color: tb.theme.focus
            font.family: tb.theme.family
            font.pixelSize: tb.theme.px(0.917)
            font.bold: true
        }
        Text {
            textFormat: Text.PlainText
            text: tb.label
            color: tb.theme.fg
            font.family: tb.theme.family
            font.pixelSize: tb.theme.px(0.917)
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
