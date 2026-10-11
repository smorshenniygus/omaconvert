pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../../services"
import "../ui"

// Key bar: what the keys do on the screen showing right now.
Rectangle {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    Layout.fillWidth: true
    implicitHeight: keyRow.implicitHeight + 14
    color: root.theme.alpha(root.theme.fg, 0.03)
    Rectangle { width: parent.width; height: 1; color: root.theme.line }
    RowLayout {
        id: keyRow
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 16
        Repeater {
            model: ({
                empty: [["⏎", "browse"], ["ctrl v", "paste"], ["drop", "a file"]],
                recipes: [["↑↓", "choose"], ["⏎", "convert"], ["alt " + (root.session.matched.rows.length > 1 ? "1–" + Math.min(9, root.session.matched.rows.length) : "1"), "pick"], ["ctrl d", root.session.activePinned ? "unpin" : "pin"], ["ctrl ,", "settings"]],
                settings: [["tab", "next field"], ["←→", "choose"], ["ctrl d", root.session.activePinned ? "unpin" : "pin"], ["ctrl ⏎", "convert"]],
                converting: [],
                result: root.service.isBatch ? [["⏎", "folder"], ["c", "copy all"], ["p", "paths"], ["n", "more"]]
                    : [["⏎", "open"], ["o", "folder"], ["c", "copy"], ["p", "path"], ["n", "another"]]
            })[root.session.screen] || []
            delegate: Row {
                id: keyHint
                required property var modelData
                spacing: 5
                MonoText {
                    theme: root.theme
                    size: 0.833
                    text: keyHint.modelData[0]
                    color: root.theme.focus
                    font.bold: true
                }
                MonoText {
                    theme: root.theme
                    size: 0.833
                    text: keyHint.modelData[1]
                    color: root.theme.dim
                }
            }
        }
        Item { Layout.fillWidth: true }
        MonoText {
            theme: root.theme
            size: 0.833
            text: root.session.screen === "settings" ? "esc back to recipes" : (root.session.screen === "converting" ? "esc cancel" : "esc close")
            color: root.theme.faint
        }
    }
}
