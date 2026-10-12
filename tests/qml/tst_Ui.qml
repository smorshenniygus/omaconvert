import QtQuick
import QtTest
import "../../components/ui" as Ui

// The building blocks take every colour and size from one Theme object:
// a stub theme is enough to render them, and the keyboard and mouse
// trigger them the same way.
TestCase {
    name: "OmaConvertUi"
    width: 400
    height: 300
    when: windowShown
    visible: true   // TestCase is hidden by default; clicks need a visible tree

    Ui.Theme { id: stub; fg: "#ffffff"; focus: "#ff0000"; body: 20 }
    property int checks: 0
    property int actions: 0
    property int clicks: 0

    Column {
        Ui.CheckRow { id: check; theme: stub; width: 300; label: "Hotkey"; onToggled: checks++ }
        Ui.ActionRow { id: action; theme: stub; width: 300; glyph: "x"; label: "Open file"; key: "⏎"; onTriggered: actions++ }
        Ui.TextButton { id: button; theme: stub; label: "change"; onClicked: clicks++ }
        Ui.SectionLabel { id: label; theme: stub; text: "SOURCE" }
    }

    function test_themeReachesTheBlocks() {
        compare(String(label.color), String(stub.faint))
        compare(label.font.pixelSize, Math.round(20 * 0.833))
        stub.fg = "#000000"
        compare(String(label.color), "#52000000", "a theme change restyles live")
        stub.fg = "#ffffff"
    }
    function test_keyboardAndMouse() {
        check.forceActiveFocus()
        keyClick(Qt.Key_Space)
        mouseClick(check)
        compare(checks, 2)
        action.forceActiveFocus()
        keyClick(Qt.Key_Return)
        mouseClick(action)
        compare(actions, 2)
        button.forceActiveFocus()
        keyClick(Qt.Key_Return)
        mouseClick(button)
        compare(clicks, 2)
    }
}
