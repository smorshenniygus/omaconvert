import QtQuick

// One line of typed text, drawn and edited here instead of by a Qt text
// input. The panel stays loaded for the whole shell session, and every
// editable Qt text input reads the clipboard whenever it changes (to know
// whether it could paste); a clipboard owner that streams endless text
// would stall the shell. This field never touches the clipboard: Ctrl+V is
// left to the window, which pastes through the backend with size limits.
//
// `text` is owned by the caller: an edit only emits `edited(newText)` and
// the caller updates what `text` is bound to.
FocusScope {
    id: root
    required property Theme theme
    property string text: ""
    property string placeholderText: ""
    property real fontSize: root.theme.body
    property bool bold: false
    property bool alignRight: false
    property real leftPadding: 10
    property real rightPadding: 10
    property real verticalPadding: 7
    property int maximumLength: 512
    // Which typed characters to take; all printable ones by default.
    property var accepts: ch => true
    property int cursorPosition: root.text.length
    signal edited(string text)
    // The text our own last edit asked for: any other change of `text`
    // (a recipe, the settings rewriting the line) puts the cursor at the end.
    property string pendingText: ""

    function setCursor(position) { root.cursorPosition = Math.max(0, Math.min(root.text.length, position)) }
    function insert(position, value) {
        var clean = String(value || "").replace(/[\r\n\t]+/g, " ").replace(/[\u0000-\u001f\u007f]/g, "")
        clean = clean.slice(0, Math.max(0, root.maximumLength - root.text.length))
        if (!clean) return
        var at = Math.max(0, Math.min(root.text.length, position))
        var next = root.text.slice(0, at) + clean + root.text.slice(at)
        root.pendingText = next
        root.edited(next)
        root.setCursor(at + clean.length)
    }
    function remove(from, to) {
        if (to <= from) return
        root.pendingText = root.text.slice(0, from) + root.text.slice(to)
        root.edited(root.pendingText)
        root.setCursor(from)
    }
    // Start of the word before `position`, for Ctrl+Backspace.
    function wordStart(position) {
        var i = position
        while (i > 0 && root.text[i - 1] === " ") i--
        while (i > 0 && root.text[i - 1] !== " ") i--
        return i
    }

    onTextChanged: if (root.text !== root.pendingText) root.cursorPosition = root.text.length
    activeFocusOnTab: true
    implicitWidth: 120
    implicitHeight: Math.ceil(metrics.height) + 2 * root.verticalPadding + 2
    Accessible.role: Accessible.EditableText
    Accessible.description: root.text

    FontMetrics {
        id: metrics
        font.family: root.theme.family
        font.pixelSize: root.fontSize
        font.bold: root.bold
    }
    TextMetrics {
        id: beforeCursor
        font: metrics.font
        text: root.text.slice(0, root.cursorPosition)
    }

    Rectangle {
        anchors.fill: parent
        color: root.activeFocus ? root.theme.alpha(root.theme.focus, 0.06)
             : (pointer.containsMouse ? root.theme.alpha(root.theme.fg, 0.06) : root.theme.surface)
        border.width: 1
        border.color: root.activeFocus ? root.theme.focus : root.theme.alpha(root.theme.fg, 0.3)
    }

    Item {
        id: viewport
        anchors.fill: parent
        anchors.leftMargin: root.leftPadding
        anchors.rightMargin: root.rightPadding
        clip: true
        // Scrolls so the cursor stays visible in a long line.
        readonly property real cursorX: beforeCursor.advanceWidth
        readonly property real shift: root.alignRight ? 0 : Math.max(0, cursorX - width + 3)

        Text {
            id: shown
            x: root.alignRight ? viewport.width - width : -viewport.shift
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.text
            color: root.theme.fg
            font: metrics.font
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            x: root.alignRight ? viewport.width - width : 0
            visible: root.text === ""
            textFormat: Text.PlainText
            text: root.placeholderText
            color: root.theme.faint
            font.family: root.theme.family
            font.pixelSize: root.fontSize
        }
        Rectangle {
            id: caret
            visible: root.activeFocus && blink.on
            x: shown.x + viewport.cursorX
            width: 2
            height: metrics.height
            anchors.verticalCenter: parent.verticalCenter
            color: root.theme.focus
        }
    }
    Timer {
        id: blink
        property bool on: true
        interval: 530
        repeat: true
        running: root.activeFocus
        onRunningChanged: on = true
        onTriggered: on = !on
    }

    // Editing keys live on an inner item, so keys it leaves alone (Enter,
    // Esc, Up, Down, Ctrl+V…) reach the handlers the caller sets on the field.
    Item {
        id: editor
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
            var at = root.cursorPosition
            blink.on = true
            if (event.key === Qt.Key_Left) root.setCursor(ctrl ? root.wordStart(at) : at - 1)
            else if (event.key === Qt.Key_Right) root.setCursor(at + 1)
            else if (event.key === Qt.Key_Home) root.setCursor(0)
            else if (event.key === Qt.Key_End) root.setCursor(root.text.length)
            else if (event.key === Qt.Key_Backspace) root.remove(ctrl ? root.wordStart(at) : Math.max(0, at - 1), at)
            else if (event.key === Qt.Key_Delete) root.remove(at, Math.min(root.text.length, at + 1))
            else if (!ctrl && !(event.modifiers & (Qt.AltModifier | Qt.MetaModifier))
                     && event.text.length > 0 && event.text.charCodeAt(0) >= 32 && root.accepts(event.text))
                root.insert(at, event.text)
            else { event.accepted = false; return }
            event.accepted = true
        }
    }
    MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.IBeamCursor
        onPressed: mouse => {
            root.forceActiveFocus()
            var charWidth = Math.max(1, metrics.averageCharacterWidth)
            var local = mouse.x - root.leftPadding - shown.x
            root.setCursor(Math.round(local / charWidth))
        }
    }
}
