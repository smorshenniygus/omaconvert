import QtQuick
import QtQuick.Layouts

// One setting: label column on the left, controls on the right.
Rectangle {
    id: fieldRow
    required property Theme theme
    property string label: ""
    default property alias controls: fieldControls.data
    Layout.fillWidth: true
    implicitHeight: fieldLayout.implicitHeight + 14
    color: "transparent"
    opacity: enabled ? 1 : 0.38
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: fieldRow.theme.line }
    RowLayout {
        id: fieldLayout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        spacing: 12
        SectionLabel {
            theme: fieldRow.theme
            Layout.preferredWidth: 84
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 5
            text: fieldRow.label
            font.letterSpacing: 1.5
        }
        ColumnLayout {
            id: fieldControls
            Layout.fillWidth: true
            // Without a filling child the column would shrink to its
            // content and float to the middle of the row.
            Layout.maximumWidth: Number.POSITIVE_INFINITY
            spacing: 5
        }
    }
}
