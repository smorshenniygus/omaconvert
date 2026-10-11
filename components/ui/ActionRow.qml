import QtQuick
import QtQuick.Layouts

// Result action: icon, label, key on the right; the first one is primary.
Rectangle {
    id: act
    required property Theme theme
    property string glyph: ""
    property string label: ""
    property string key: ""
    property bool primary: false
    signal triggered()
    Layout.fillWidth: true
    implicitHeight: actRow.implicitHeight + 20
    color: act.primary ? act.theme.alpha(act.theme.focus, 0.08) : (actMouse.containsMouse ? act.theme.surface : "transparent")
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: act.label
    // Enter on a focused action runs it: without this the window's
    // Enter shortcut (open the result) wins over Keys.onReturnPressed.
    Keys.onShortcutOverride: event => event.accepted = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
    Keys.onReturnPressed: act.triggered()
    Keys.onEnterPressed: act.triggered()
    Keys.onSpacePressed: act.triggered()
    Rectangle { visible: act.primary || act.activeFocus; width: 2; height: parent.height; color: act.theme.focus }
    Rectangle { visible: !act.primary; anchors.bottom: parent.bottom; width: parent.width; height: 1; color: act.theme.line }
    RowLayout {
        id: actRow
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        spacing: 12
        Text {
            text: act.glyph
            color: act.primary ? act.theme.focus : act.theme.mist
            font.family: act.theme.iconFamily
            font.pixelSize: act.theme.px(1.167)
        }
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: act.label
            color: act.theme.fg
            font.family: act.theme.family
            font.pixelSize: act.theme.px(1)
            font.bold: act.primary
            elide: Text.ElideRight
        }
        Text {
            textFormat: Text.PlainText
            text: act.key
            color: act.primary ? act.theme.focus : act.theme.faint
            font.family: act.theme.family
            font.pixelSize: act.theme.px(0.917)
            font.bold: true
        }
    }
    MouseArea {
        id: actMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: act.triggered()
    }
}
