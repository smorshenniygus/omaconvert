pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "ui"

// Segmented choice in the panel's terminal idiom: one bordered strip, the
// chosen cell tinted with the selection color, a focus-colored border while
// the strip has keyboard focus. Left/Right (or h/l) pick the neighbour.
// `options` are strings or { value, label } objects; `changed(value)` fires
// on every user pick. `value` is owned by the caller: a pick only emits
// `changed` and the caller updates the property `value` is bound to, so the
// binding (and the highlight) keeps following the model after any click.
// Colours and type come from one Theme object (tests pass a stub).
Rectangle {
    id: root
    required property Theme theme
    property var options: []
    property string value: ""
    signal changed(string value)

    function optionValue(o) { return (o && typeof o === "object") ? String(o.value) : String(o) }
    function optionLabel(o) { return (o && typeof o === "object") ? String(o.label) : String(o) }
    function currentIndex() {
        for (var i = 0; i < options.length; i++) if (optionValue(options[i]) === value) return i
        return -1
    }
    function pick(index) {
        if (index < 0 || index >= options.length) return
        var v = optionValue(options[index])
        if (v !== value) root.changed(v)
    }

    Layout.alignment: Qt.AlignLeft
    implicitWidth: cells.implicitWidth + 2
    implicitHeight: cells.implicitHeight + 2
    color: "transparent"
    border.width: 1
    border.color: root.activeFocus ? root.theme.focus : root.theme.alpha(root.theme.fg, 0.3)
    opacity: enabled ? 1 : 0.38
    activeFocusOnTab: enabled
    Accessible.role: Accessible.PageTabList

    Keys.onLeftPressed: event => { root.pick(Math.max(0, root.currentIndex() - 1)); event.accepted = true }
    Keys.onRightPressed: event => { root.pick(Math.min(root.options.length - 1, root.currentIndex() + 1)); event.accepted = true }
    Keys.onPressed: event => {
        if (event.text === "h") { root.pick(Math.max(0, root.currentIndex() - 1)); event.accepted = true }
        else if (event.text === "l") { root.pick(Math.min(root.options.length - 1, root.currentIndex() + 1)); event.accepted = true }
    }

    Row {
        id: cells
        x: 1
        y: 1
        Repeater {
            model: root.options
            delegate: Rectangle {
                id: cell
                required property var modelData
                required property int index
                readonly property bool on: root.optionValue(cell.modelData) === root.value
                implicitWidth: label.implicitWidth + 18
                implicitHeight: label.implicitHeight + 8
                color: cell.on ? root.theme.alpha(root.theme.sage, 0.28)
                     : (mouse.containsMouse ? root.theme.alpha(root.theme.fg, 0.06) : "transparent")
                Rectangle {
                    visible: cell.index > 0
                    width: 1
                    height: parent.height
                    color: root.theme.alpha(root.theme.fg, 0.15)
                }
                Text {
                    id: label
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.optionLabel(cell.modelData)
                    color: cell.on ? root.theme.fg : root.theme.alpha(root.theme.fg, 0.55)
                    font.family: root.theme.family
                    font.pixelSize: root.theme.px(0.917)
                    font.bold: cell.on
                }
                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.forceActiveFocus(); root.pick(cell.index) }
                }
            }
        }
    }
}
