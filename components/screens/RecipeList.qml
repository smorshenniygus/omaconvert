pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../../services"
import "../../services/Model.js" as Model
import "../ui"

// Recipes for this file, filtered by the command line: number, format,
// what it makes and why; a click or Enter runs one.
ColumnLayout {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    property string homeDir: ""
    Layout.fillWidth: true
    visible: !root.session.advanced
    spacing: 0
    Repeater {
        model: root.session.matched.rows
        delegate: Rectangle {
            id: recipeRow
            required property var modelData
            required property int index
            readonly property bool current: recipeRow.index === root.session.selectedRow
            readonly property bool blocked: recipeRow.modelData.problem !== ""
            readonly property string detail: Model.recipeDetail(recipeRow.modelData.fields, root.session.inputKind, root.service.metadata, root.session.convertSeconds)
            readonly property string note: Model.recipeNote(recipeRow.modelData.fields, root.session.inputKind, root.session.convertSeconds)
            Layout.fillWidth: true
            implicitHeight: recipeLine.implicitHeight + 18
            color: recipeRow.current ? root.theme.alpha(root.theme.focus, 0.08)
                 : (recipeMouse.containsMouse ? root.theme.surface : "transparent")
            Accessible.role: Accessible.Button
            Accessible.name: recipeRow.modelData.title + ". " + (recipeRow.modelData.problem || recipeRow.detail)
            Rectangle { visible: recipeRow.current; width: 2; height: parent.height; color: root.theme.focus }
            Rectangle { visible: !recipeRow.current; anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.theme.line }
            RowLayout {
                id: recipeLine
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                spacing: 14
                MonoText {
                    theme: root.theme
                    size: 0.917
                    text: recipeRow.index < 9 ? String(recipeRow.index + 1) : ""
                    color: recipeRow.current ? root.theme.focus : root.theme.faint
                    font.bold: true
                }
                MonoText {
                    theme: root.theme
                    size: 0.833
                    Layout.preferredWidth: root.theme.px(3.5)
                    text: (recipeRow.modelData.fields.format === Model.SEQUENCE ? "SEQ" : recipeRow.modelData.fields.format).toUpperCase()
                    color: root.theme.mist
                    font.bold: true
                    font.letterSpacing: 1
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    MonoText {
                        theme: root.theme
                        size: 1.083
                        Layout.fillWidth: true
                        text: recipeRow.modelData.title
                        opacity: recipeRow.blocked ? 0.5 : 1
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    MonoText {
                        theme: root.theme
                        size: 0.833
                        Layout.fillWidth: true
                        text: recipeRow.modelData.problem || recipeRow.note || recipeRow.detail
                        color: recipeRow.blocked ? root.theme.urgent : (recipeRow.note ? root.theme.fg : root.theme.dim)
                        wrapMode: Text.WordWrap
                    }
                }
                MonoText {
                    theme: root.theme
                    size: 0.833
                    text: recipeRow.modelData.pinned ? "★ pinned" : (recipeRow.modelData.last ? "last used" : (recipeRow.modelData.custom ? "as typed" : ""))
                    visible: text !== ""
                    color: recipeRow.current ? root.theme.fg : root.theme.faint
                }
                MonoText {
                    theme: root.theme
                    size: 1.083
                    text: "⏎"
                    visible: recipeRow.current && !recipeRow.blocked
                    color: root.theme.focus
                    font.bold: true
                }
            }
            MouseArea {
                id: recipeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: recipeRow.blocked ? Qt.ArrowCursor : Qt.PointingHandCursor
                // Only a moving pointer selects: a row sliding under a
                // still cursor must not change the selection.
                onPositionChanged: if (root.session.selectedRow !== recipeRow.index) root.session.selectedRow = recipeRow.index
                onClicked: root.session.runRecipe(recipeRow.index)
            }
        }
    }
    Hint {
        theme: root.theme
        Layout.topMargin: 6
        visible: text !== ""
        text: root.session.matched.note
        color: root.theme.fg
    }
    Hint {
        theme: root.theme
        Layout.topMargin: 6
        visible: root.session.outputFolder !== ""
        text: "saves to " + Model.folderLabel(root.session.outputFolder, root.homeDir)
    }
}
