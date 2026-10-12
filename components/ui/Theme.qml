import QtQuick

// Colours and type sizes for every OmaConvert component, passed down as one
// object. The window fills it from the Omarchy theme; the defaults are a
// neutral dark palette, so tests render components without the shell.
QtObject {
    id: theme
    property color fg: "#cacccc"
    property color bg: "#101315"
    property color accent: "#cacccc"
    property color urgent: "#a55555"
    // Selected, hovered and focused states.
    property color sage: "#819890"
    property color mist: "#a3b5ae"
    property color focus: "#f4e276"
    // Text; Nerd Font glyphs use iconFamily.
    property string family: "monospace"
    property string iconFamily: "monospace"
    property int body: 12
    property int bodySmall: 11
    property int caption: 10
    readonly property color dim: theme.alpha(theme.fg, 0.55)
    readonly property color faint: theme.alpha(theme.fg, 0.32)
    readonly property color line: theme.alpha(theme.fg, 0.16)
    readonly property color surface: theme.alpha(theme.fg, 0.04)
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    // Text size relative to the body size.
    function px(k) { return Math.round(theme.body * k) }
}
