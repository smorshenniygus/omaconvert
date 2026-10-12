pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Ui as Ui
import "../../services"
import "../ui"

// Title bar: the app, its version, what the window is doing, close.
Rectangle {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    required property string appVersion
    signal closeRequested()
    Layout.fillWidth: true
    implicitHeight: titleRow.implicitHeight + 20
    color: "transparent"
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.theme.line }
    RowLayout {
        id: titleRow
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 12
        spacing: 10
        Text {
            text: "󰕧"
            color: root.theme.sage
            font.family: root.theme.iconFamily
            font.pixelSize: root.theme.px(1.333)
        }
        MonoText {
            theme: root.theme
            text: "omaconvert"
            font.bold: true
        }
        MonoText {
            theme: root.theme
            text: "v" + root.appVersion
            color: root.theme.faint
            Accessible.name: "OmaConvert version " + root.appVersion
        }
        Item { Layout.fillWidth: true }
        Rectangle {
            readonly property string label: root.session.screen === "converting" ? "CONVERTING"
                : (root.session.screen === "result" ? "READY"
                : (root.service.metadata ? (root.session.inputKind === "image" ? "IMAGE" : "VIDEO") : ""))
            readonly property color tone: root.session.screen === "converting" ? root.theme.focus : root.theme.mist
            visible: label !== ""
            implicitWidth: stateText.implicitWidth + 16
            implicitHeight: stateText.implicitHeight + 4
            color: root.theme.alpha(tone, 0.13)
            border.width: 1
            border.color: tone
            MonoText {
                id: stateText
                theme: root.theme
                size: 0.833
                anchors.centerIn: parent
                text: parent.label
                color: parent.tone
                font.bold: true
                font.letterSpacing: 1.5
            }
        }
        Ui.PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Close  ·  Esc"
            foreground: root.theme.fg
            hoverColor: root.theme.urgent
            Accessible.name: "Close OmaConvert"
            onClicked: root.closeRequested()
        }
    }
}
