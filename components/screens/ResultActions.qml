pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../ui"

// Result actions as rows: icon, label and key, the first one primary.
// `actions` is the window's list of {key, hint, glyph, label, run}.
ColumnLayout {
    id: root
    required property Theme theme
    property var actions: []
    Layout.fillWidth: true
    spacing: 0
    Repeater {
        model: root.actions
        delegate: ActionRow {
            id: row
            required property var modelData
            required property int index
            theme: root.theme
            primary: row.index === 0
            glyph: row.modelData.glyph
            key: row.modelData.key
            label: row.modelData.label
            onTriggered: row.modelData.run()
        }
    }
}
