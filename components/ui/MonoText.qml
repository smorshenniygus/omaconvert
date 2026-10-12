import QtQuick

// Plain text in the panel's family; `size` is relative to the body size.
Text {
    id: mono
    required property Theme theme
    property real size: 1
    textFormat: Text.PlainText
    color: mono.theme.fg
    font.family: mono.theme.family
    font.pixelSize: mono.theme.px(mono.size)
}
