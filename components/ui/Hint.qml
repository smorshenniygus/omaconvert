import QtQuick
import QtQuick.Layouts

// A wrapped line of help or status under a block.
Text {
    id: hint
    required property Theme theme
    textFormat: Text.PlainText
    Layout.fillWidth: true
    color: hint.theme.dim
    font.family: hint.theme.family
    font.pixelSize: hint.theme.caption
    wrapMode: Text.WordWrap
}
