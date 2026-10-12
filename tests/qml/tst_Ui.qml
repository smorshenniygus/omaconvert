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
    property string owned: ""
    property string sizeText: "50"

    Column {
        Ui.CheckRow { id: check; theme: stub; width: 300; label: "Hotkey"; onToggled: checks++ }
        Ui.ActionRow { id: action; theme: stub; width: 300; glyph: "x"; label: "Open file"; key: "⏎"; onTriggered: actions++ }
        Ui.TextButton { id: button; theme: stub; label: "change"; onClicked: clicks++ }
        Ui.SectionLabel { id: label; theme: stub; text: "SOURCE" }
        Ui.LineEdit { id: line; theme: stub; width: 300; text: owned; onEdited: value => owned = value }
        Ui.LineEdit { id: size; theme: stub; width: 100; text: sizeText; accepts: ch => /^[0-9.]$/.test(ch); onEdited: value => sizeText = value }
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
    // Typing, cursor keys and deletion edit the caller's text through
    // edited(); the binding to `text` keeps following the caller.
    function test_lineEditKeys() {
        line.forceActiveFocus()
        keyClick(Qt.Key_G); keyClick(Qt.Key_I); keyClick(Qt.Key_F)
        compare(owned, "gif")
        keyClick(Qt.Key_Left); keyClick(Qt.Key_Left)
        keyClick(Qt.Key_X)
        compare(owned, "gxif")
        keyClick(Qt.Key_Backspace)
        compare(owned, "gif")
        keyClick(Qt.Key_End); keyClick(Qt.Key_Space); keyClick(Qt.Key_1); keyClick(Qt.Key_0)
        compare(owned, "gif 10")
        keyClick(Qt.Key_Backspace, Qt.ControlModifier)
        compare(owned, "gif ")
        keyClick(Qt.Key_Home); keyClick(Qt.Key_Delete)
        compare(owned, "if ")
        owned = "webm"
        compare(line.text, "webm", "an outside change still reaches the field")
        line.insert(line.cursorPosition, "  2mb\n")
        compare(owned, "webm  2mb ")
        size.forceActiveFocus()
        keyClick(Qt.Key_A); keyClick(Qt.Key_Period); keyClick(Qt.Key_5)
        compare(sizeText, "50.5", "only accepted characters are typed")
    }
}
