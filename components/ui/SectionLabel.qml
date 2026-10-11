import QtQuick

// Small spaced capitals above a block: "SOURCE", "BATCH".
Text {
    id: label
    required property Theme theme
    textFormat: Text.PlainText
    color: label.theme.faint
    font.family: label.theme.family
    font.pixelSize: label.theme.px(0.833)
    font.bold: true
    font.letterSpacing: 2
}
