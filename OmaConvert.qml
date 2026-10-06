pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "services"
import "services/Model.js" as Model
import "components"

Item {
    id: root
    property var shell: null
    property var manifest: null
    property bool opened: false
    property bool checked: false
    property bool closingFromHost: false
    readonly property var menuTheme: Color.menu
    readonly property var fonts: Style.font
    readonly property var spacing: Style.spacing
    property url settingsLocation: Model.fileUri(root.configRoot + "/omaconvert/preferences.ini")
    property string clipboardText: ""
    property string clipboardStatus: ""
    readonly property string configRoot: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    readonly property bool pickerBusy: filePicker.running || folderPicker.running
    readonly property string homeDir: Quickshell.env("HOME") || ""
    // Destination folder for the next conversion; "" saves next to the source.
    // Only persisted (prefs.savedFolder) when the user asked to remember it.
    property string outputFolder: ""
    readonly property var convertService: service
    readonly property var previewService: preview
    readonly property var panelWindow: window
    readonly property var panelCard: card
    readonly property var trimControl: trimBar
    readonly property var commandField: commandInput
    readonly property string inputKind: service.metadata && service.metadata.kind === "image" ? "image" : "video"
    // Readable line length at any window size: narrow windows use every
    // pixel, wide/fullscreen ones get a centered column instead of a
    // stretched single row.
    readonly property int maxContentWidth: 640
    readonly property string appVersion: Model.VERSION
    // Backend files on disk are newer/older than this loaded QML: the shell
    // kept a cached interface after `omarchy plugin update`.
    readonly property bool staleInterface: service.backendVersion !== "" && service.backendVersion !== root.appVersion
    // Palette: theme roles only, so every Omarchy theme dresses the panel.
    readonly property color fg: root.menuTheme.text
    readonly property color bg: root.menuTheme.background
    readonly property color accent: Color.accent
    readonly property color urgent: Color.urgent
    readonly property color dim: root.alpha(root.fg, 0.55)
    readonly property color faint: root.alpha(root.fg, 0.32)
    readonly property color line: root.alpha(root.fg, 0.16)
    readonly property color surface: root.alpha(root.fg, 0.04)
    readonly property color sage: Style.selectedStateColor(root.fg, root.accent, root.urgent)
    readonly property color mist: Style.hoverStateColor(root.fg, root.accent, root.urgent)
    readonly property color focusColor: Style.focusStateColor(root.fg, root.accent, root.urgent)
    readonly property string fontFamily: root.fonts.menuFamily
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    function px(k) { return Math.round(root.fonts.body * k) }
    // Form state (persisted through Settings aliases below).
    property string formatValue: ""
    property int modeIndex: 0
    property int unitIndex: 0
    property int preferenceIndex: 1
    property int presetIndex: 1
    property int sequenceFps: 0
    // Recipe list vs. every field ("+"); which recipe Enter runs.
    property bool advanced: false
    property int selectedRow: 0
    readonly property var formatOptions: Model.commandFormats(root.inputKind, service.capabilities)
    readonly property string unavailableFormats: Model.unavailableText(root.inputKind, service.capabilities)
    readonly property string audioProblem: Model.audioProblem(root.formatValue, service.metadata, service.capabilities)
    readonly property string unitText: ["MB", "KB"][root.unitIndex] || "MB"
    onFormatOptionsChanged: if (root.formatOptions.indexOf(root.formatValue) < 0) Qt.callLater(root.resetRecipes)
    Component.onCompleted: {
        if (prefs.rememberFolder) root.outputFolder = prefs.savedFolder
    }
    readonly property bool trimShown: service.metadata !== null && service.metadata.kind !== "image" && (service.metadata.duration || 0) > 0
    readonly property bool sizeShown: root.modeIndex === 0 && root.formatValue !== Model.SEQUENCE
    // Seconds that will be converted: the trimmed part of a video.
    readonly property real convertSeconds: root.trimShown ? Math.max(0, trimBar.endTime - trimBar.startTime) : ((service.metadata && service.metadata.duration) || 0)
    readonly property string lastCommand: root.inputKind === "image" ? prefs.lastImageCommand : prefs.lastVideoCommand
    readonly property var matched: service.metadata
        ? Model.matchRecipes(commandInput.text, root.inputKind, service.metadata, service.capabilities, root.lastCommand, root.convertSeconds)
        : ({ rows: [], chips: [], note: "" })
    readonly property var fieldsRecipe: Model.recipe(root.currentFields(), root.inputKind, service.metadata, service.capabilities, root.convertSeconds)
    readonly property bool readyToConvert: !service.busy && !root.pickerBusy && service.metadata !== null && service.dependenciesReady && (!root.trimShown || trimBar.valid)
    readonly property bool canConvert: root.readyToConvert && (!root.sizeShown || Model.validSize(sizeInput.text)) && root.audioProblem === "" && root.formatOptions.indexOf(root.formatValue) >= 0
    // Format that Enter would run: the fields with "+" open, else the highlighted recipe.
    readonly property string activeFormat: root.advanced ? root.formatValue
        : (root.selectedRow < root.matched.rows.length ? root.matched.rows[root.selectedRow].fields.format : "")
    // What Enter would make: the fields with settings open, else the highlighted recipe.
    readonly property var activeFields: root.advanced ? root.currentFields()
        : (root.selectedRow < root.matched.rows.length ? root.matched.rows[root.selectedRow].fields : null)
    readonly property real activeLimit: root.activeFields && root.activeFields.mode === "target" && root.activeFields.format !== Model.SEQUENCE
        ? Model.limitBytes(root.activeFields.size, root.activeFields.unit) : 0
    // The running job, for the converting screen.
    property real jobLimitBytes: 0
    property string jobCommand: ""
    property real clock: Date.now()
    readonly property bool idleWithFile: service.metadata !== null && !service.result && !service.busy
    readonly property string screen: service.result && !service.busy ? "result"
        : (service.busy && service.operation === "convert" ? "converting"
        : (root.idleWithFile ? (root.advanced ? "settings" : "recipes") : "empty"))
    readonly property bool canRunSelected: root.readyToConvert && root.selectedRow < root.matched.rows.length && root.matched.rows[root.selectedRow].problem === ""

    function open(payloadJson) {
        closingFromHost = false
        opened = true
        window.visible = true
        var payload = {}
        try { payload = JSON.parse(payloadJson || "{}") } catch (_) {}
        if (payload.file) {
            var requestedPath = Model.localPath(payload.file)
            if (requestedPath) service.selectFile(requestedPath)
            else service.error = "Choose a local file, not a remote URL."
        }
        else if (!checked && !service.busy) { checked = true; service.check() }
        service.loadCapabilities()
        service.loadOpenWith()
        Qt.callLater(() => choose.forceActiveFocus())
    }
    // Fields <-> the command line. A recipe, the typed text and the "+"
    // panel all end up as these root properties; startConversion() reads them.
    function currentFields() {
        return {
            format: root.formatValue,
            mode: root.modeIndex === 1 || root.formatValue === Model.SEQUENCE ? "quick" : "target",
            size: sizeInput.text, unit: root.unitText,
            preference: Model.PREFERENCES[root.preferenceIndex] || "balanced",
            preset: Model.PRESETS[root.presetIndex] || "balanced",
            sequenceFps: root.sequenceFps
        }
    }
    function applyFields(fields) {
        if (!fields) return
        if (fields.format) root.formatValue = fields.format
        if (fields.mode) root.modeIndex = fields.mode === "quick" ? 1 : 0
        if (fields.size) sizeInput.text = fields.size
        if (fields.unit) root.unitIndex = fields.unit === "KB" ? 1 : 0
        if (fields.preference) root.preferenceIndex = Math.max(0, Model.PREFERENCES.indexOf(fields.preference))
        if (fields.preset) root.presetIndex = Math.max(0, Model.PRESETS.indexOf(fields.preset))
        if (fields.sequenceFps !== undefined) root.sequenceFps = Number(fields.sequenceFps) || 0
    }
    // A panel edit rewrites the line (setting text does not emit textEdited).
    function syncCommand() {
        if (root.advanced) commandInput.text = Model.commandText(root.currentFields(), root.inputKind)
    }
    // Typing filters the recipes; with the panel open it also fills the fields.
    function commandEdited() {
        root.selectedRow = 0
        if (root.advanced) root.applyFields(Model.parseCommand(commandInput.text, root.inputKind, root.formatOptions).fields)
    }
    function moveSelection(step) {
        if (!root.advanced) root.selectedRow = Math.max(0, Math.min(root.matched.rows.length - 1, root.selectedRow + step))
    }
    function commandReturn(event) {
        // Ctrl+Enter belongs to the window shortcut.
        if (event.modifiers & Qt.ControlModifier) { event.accepted = false; return }
        event.accepted = true
        if (root.advanced) root.startConversion()
        else root.runRecipe(root.selectedRow)
    }
    function runRecipe(index) {
        var row = root.matched.rows[index]
        if (!row || row.problem !== "" || !root.readyToConvert) return
        root.applyFields(row.fields)
        root.startConversion()
    }
    function toggleAdvanced() {
        if (root.advanced) {
            root.advanced = false
            root.selectedRow = 0
            return
        }
        var row = root.matched.rows[root.selectedRow] || root.matched.rows[0]
        if (row) root.applyFields(row.fields)
        root.advanced = true
        root.syncCommand()
    }
    // A newly read file starts from its recipes, the last used one first.
    function resetRecipes() {
        root.advanced = false
        root.selectedRow = 0
        commandInput.text = ""
        var first = Model.recipes(root.inputKind, service.metadata, service.capabilities, root.lastCommand, root.convertSeconds)[0]
        if (first) root.applyFields(first.fields)
        else if (root.formatOptions.indexOf(root.formatValue) < 0) root.formatValue = root.formatOptions[0] || ""
    }
    function chooseVideo() {
        if (!service.busy && !filePicker.running) filePicker.running = true
    }
    function chooseFolder() {
        if (!service.busy && !root.pickerBusy) folderPicker.running = true
    }
    function setOutputFolder(path) {
        root.outputFolder = path || ""
        if (prefs.rememberFolder) prefs.savedFolder = root.outputFolder
    }
    function toggleRememberFolder() {
        prefs.rememberFolder = !prefs.rememberFolder
        prefs.savedFolder = prefs.rememberFolder ? root.outputFolder : ""
    }
    function pathFromUri(uri) {
        var value = String(uri || "").trim().split("\n")[0].trim()
        if (value.indexOf("/") === 0) return value
        return Model.localPath(value)
    }
    function close() {
        closingFromHost = true
        service.cancel()
        if (filePicker.running) filePicker.running = false
        if (folderPicker.running) folderPicker.running = false
        opened = false
        window.visible = false
        closingFromHost = false
    }
    function dismiss() {
        // User-initiated close: keep host openPanelIds in sync so toggle() works.
        if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || Model.PLUGIN_ID)
        else close()
    }
    function toggle() { if (opened) dismiss(); else open("{}") }
    function startConversion() {
        if (!canConvert) return
        var command = Model.commandText(root.currentFields(), root.inputKind)
        root.jobCommand = command
        root.jobLimitBytes = root.sizeShown ? Model.limitBytes(sizeInput.text, root.unitText) : 0
        if (root.inputKind === "image") prefs.lastImageCommand = command
        else prefs.lastVideoCommand = command
        prefs.sync()
        clipboardStatus = ""
        var useTrim = root.trimShown
        var sequence = root.formatValue === Model.SEQUENCE
        service.convert(sequence ? "png" : root.formatValue.toLowerCase(), root.sizeShown ? "target" : "quick",
                        sizeInput.text, root.unitText, Model.PRESETS[root.presetIndex] || "balanced",
                        Model.PREFERENCES[root.preferenceIndex] || "balanced",
                        useTrim ? trimBar.startTime : 0, useTrim ? trimBar.endTime : 0, root.outputFolder,
                        sequence ? root.sequenceFps : null)
    }
    function convertAnother() {
        service.result = null
        service.metadata = null
        service.inputPath = ""
        service.phase = ""
        root.clipboardStatus = ""
        preview.clearAll()
        choose.forceActiveFocus()
    }
    function openResultFolder() {
        var path = service.result ? service.result.path : ""
        Qt.openUrlExternally(Model.fileUri(path.substring(0, path.lastIndexOf("/")) || "/"))
    }
    function copy(value, uri) {
        if (clipboard.running) return
        clipboardText = value
        clipboard.command = ["wl-copy", "--type", uri ? "text/uri-list" : "text/plain;charset=utf-8"]
        clipboard.running = true
    }
    Settings {
        id: prefs
        location: root.settingsLocation
        // Last conversion per input kind, as command words ("gif 50mb");
        // offered first the next time a file of that kind is opened.
        property string lastVideoCommand: ""
        property string lastImageCommand: ""
        property alias modeIndex: root.modeIndex
        property alias sizeText: sizeInput.text
        property alias unitIndex: root.unitIndex
        property alias preferenceIndex: root.preferenceIndex
        property alias presetIndex: root.presetIndex
        property bool rememberFolder: false
        property string savedFolder: ""
    }
    ConvertService {
        id: service
        executable: Model.localPath(Qt.resolvedUrl("bin/omaconvert"))
        onMetadataChanged: {
            if (service.metadata && service.inputPath) {
                preview.clearResult()
                preview.requestSource(service.inputPath)
                // Deferred past binding propagation so TrimBar.duration is current.
                Qt.callLater(() => {
                    trimBar.reset()
                    root.resetRecipes()
                    if (root.opened) commandInput.forceActiveFocus()
                })
            } else if (!service.metadata) {
                preview.clearSource()
            }
        }
        onResultChanged: {
            // A PNG sequence is a folder: preview its first frame.
            if (service.result && service.result.path) preview.requestResult(service.result.first_frame || service.result.path)
            else preview.clearResult()
        }
        onInputPathChanged: {
            if (!service.inputPath) preview.clearAll()
        }
    }
    PreviewService {
        id: preview
        executable: Model.localPath(Qt.resolvedUrl("bin/omaconvert"))
    }
    Process {
        id: clipboard
        stdinEnabled: true
        onStarted: { write(root.clipboardText); stdinEnabled = false }
        // Installed Quickshell qmltypes omit QProcess::ExitStatus.
        // qmllint disable signal-handler-parameters
        onExited: (code) => { root.clipboardStatus = code === 0 ? "Copied" : "Clipboard unavailable; check wl-copy."; stdinEnabled = true }
        // qmllint enable signal-handler-parameters
    }
    // Native desktop picker via xdg portal. QML FileDialog inside a
    // layer-shell PanelWindow segfaults Qt (QQuickFileDialog::onShow ->
    // QQuickPopup::setPopupType); the external picker keeps the crash
    // out of the long-running shell process entirely.
    Process {
        id: filePicker
        command: ["omarchy-file-select", "--title", "Choose a video or image",
                  "--extensions", Model.pickerExtensions(service.capabilities)]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var path = root.pathFromUri(text)
                if (path) service.selectFile(path)
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: (code) => {
            if (code > 1) service.error = "Could not open file picker. Drop a local file onto Choose instead."
            if (root.opened) Qt.callLater(() => choose.forceActiveFocus())
        }
        // qmllint enable signal-handler-parameters
    }

    Process {
        id: folderPicker
        command: ["omarchy-file-select", "--title", "Choose where to save the result", "--directory"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var path = root.pathFromUri(text)
                if (path) root.setOutputFolder(path)
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: (code) => {
            if (code > 1) service.error = "Could not open the folder picker."
        }
        // qmllint enable signal-handler-parameters
    }

    // ── Building blocks (terminal idiom: square, 1 px lines, mono) ─────────
    component SectionLabel: Text {
        readonly property var fontTokens: Style.font
        textFormat: Text.PlainText
        color: root.faint
        font.family: fontTokens.menuFamily
        font.pixelSize: Math.round(fontTokens.body * 0.833)
        font.bold: true
        font.letterSpacing: 2
    }
    component Hint: Text {
        readonly property var fontTokens: Style.font
        textFormat: Text.PlainText
        Layout.fillWidth: true
        color: root.dim
        font.family: fontTokens.menuFamily
        font.pixelSize: fontTokens.caption
        wrapMode: Text.WordWrap
    }
    component ActionButton: Ui.Button {
        readonly property var menuTheme: Color.menu
        readonly property var fontTokens: Style.font
        bordered: true
        focusable: true
        foreground: menuTheme.text
        accent: Color.accent
        fontFamily: fontTokens.menuFamily
        opacity: enabled ? 1 : 0.4
    }
    // Small bordered text button: "change", "×", "esc cancel".
    component TextButton: Rectangle {
        id: tb
        property string key: ""
        property string label: ""
        signal clicked()
        implicitWidth: tbRow.implicitWidth + 18
        implicitHeight: tbRow.implicitHeight + 8
        color: tbMouse.containsMouse ? root.alpha(root.fg, 0.06) : "transparent"
        border.width: 1
        border.color: tb.activeFocus ? root.focusColor : root.alpha(root.fg, 0.3)
        opacity: enabled ? 1 : 0.4
        activeFocusOnTab: enabled
        Accessible.role: Accessible.Button
        Accessible.name: tb.label
        Keys.onReturnPressed: tb.clicked()
        Keys.onEnterPressed: tb.clicked()
        Keys.onSpacePressed: tb.clicked()
        Row {
            id: tbRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                visible: tb.key !== ""
                textFormat: Text.PlainText
                text: tb.key
                color: root.focusColor
                font.family: root.fontFamily
                font.pixelSize: root.px(0.917)
                font.bold: true
            }
            Text {
                textFormat: Text.PlainText
                text: tb.label
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: root.px(0.917)
            }
        }
        MouseArea {
            id: tbMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tb.clicked()
        }
    }
    // One setting: label column on the left, controls on the right.
    component FieldRow: Rectangle {
        id: fieldRow
        property string label: ""
        default property alias controls: fieldControls.data
        Layout.fillWidth: true
        implicitHeight: fieldLayout.implicitHeight + 14
        color: "transparent"
        opacity: enabled ? 1 : 0.38
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.line }
        RowLayout {
            id: fieldLayout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 12
            SectionLabel {
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
    // Result action: icon, label, key on the right; the first one is primary.
    component ActionRow: Rectangle {
        id: act
        property string glyph: ""
        property string label: ""
        property string key: ""
        property bool primary: false
        signal triggered()
        Layout.fillWidth: true
        implicitHeight: actRow.implicitHeight + 20
        color: act.primary ? root.alpha(root.focusColor, 0.08) : (actMouse.containsMouse ? root.surface : "transparent")
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: act.label
        Keys.onReturnPressed: act.triggered()
        Keys.onEnterPressed: act.triggered()
        Keys.onSpacePressed: act.triggered()
        Rectangle { visible: act.primary || act.activeFocus; width: 2; height: parent.height; color: root.focusColor }
        Rectangle { visible: !act.primary; anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.line }
        RowLayout {
            id: actRow
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 12
            Text {
                text: act.glyph
                color: act.primary ? root.focusColor : root.mist
                font.family: root.fonts.family
                font.pixelSize: root.px(1.167)
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: act.label
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: root.px(1)
                font.bold: act.primary
                elide: Text.ElideRight
            }
            Text {
                textFormat: Text.PlainText
                text: act.key
                color: act.primary ? root.focusColor : root.faint
                font.family: root.fontFamily
                font.pixelSize: root.px(0.917)
                font.bold: true
            }
        }
        MouseArea {
            id: actMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: act.triggered()
        }
    }

    // Quickshell creates FloatingWindow through its runtime platform factory.
    // qmllint disable uncreatable-type
    FloatingWindow {
        // qmllint enable uncreatable-type
        id: window
        title: "OmaConvert"
        // Quickshell windows default to visible: keep hidden until open().
        // Otherwise keepLoaded instantiation pops the window at every boot.
        visible: false
        color: root.bg
        implicitWidth: 560
        implicitHeight: 880
        minimumSize: Qt.size(460, 520)

        onVisibleChanged: {
            if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
                root.shell.hide((root.manifest && root.manifest.id) || Model.PLUGIN_ID)
        }

        FocusScope {
            id: card
            anchors.fill: parent
            focus: true
            // Kept for tests/tools that read the usable content width.
            readonly property real availableWidth: width - 40
            // Own background: identical to the window color, and grabs
            // (screenshots, tests) see the real panel instead of alpha.
            Rectangle { anchors.fill: parent; color: root.bg }
            Keys.onEscapePressed: event => {
                if (service.busy) service.cancel()
                else if (root.screen === "settings") root.toggleAdvanced()
                else root.dismiss()
                event.accepted = true
            }

            Shortcut {
                sequences: ["Ctrl+Return", "Ctrl+Enter"]
                enabled: root.opened && window.visible && !root.pickerBusy && (root.advanced ? root.canConvert : root.canRunSelected)
                context: Qt.WindowShortcut
                onActivated: root.advanced ? root.startConversion() : root.runRecipe(root.selectedRow)
            }
            Shortcut {
                sequence: "Ctrl+,"
                enabled: root.idleWithFile
                context: Qt.WindowShortcut
                onActivated: root.toggleAdvanced()
            }
            // Alt+1… runs a recipe: plain digits belong to the command line.
            Repeater {
                model: 9
                delegate: Item {
                    id: recipeKey
                    required property int index
                    Shortcut {
                        sequence: "Alt+" + (recipeKey.index + 1)
                        enabled: root.screen === "recipes" && recipeKey.index < root.matched.rows.length
                        context: Qt.WindowShortcut
                        onActivated: root.runRecipe(recipeKey.index)
                    }
                }
            }
            Shortcut { sequences: ["Return", "Enter"]; enabled: root.screen === "result"; context: Qt.WindowShortcut; onActivated: Qt.openUrlExternally(Model.fileUri(service.result.path)) }
            Shortcut { sequence: "O"; enabled: root.screen === "result"; context: Qt.WindowShortcut; onActivated: root.openResultFolder() }
            Shortcut { sequence: "C"; enabled: root.screen === "result"; context: Qt.WindowShortcut; onActivated: root.copy(Model.fileUri(service.result.path) + "\r\n", true) }
            Shortcut { sequence: "P"; enabled: root.screen === "result"; context: Qt.WindowShortcut; onActivated: root.copy(service.result.path, false) }
            Shortcut { sequence: "N"; enabled: root.screen === "result"; context: Qt.WindowShortcut; onActivated: root.convertAnother() }
            Timer {
                interval: 1000
                repeat: true
                running: service.busy
                onTriggered: root.clock = Date.now()
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // ── Title bar ─────────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: titleRow.implicitHeight + 20
                    color: "transparent"
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.line }
                    RowLayout {
                        id: titleRow
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 12
                        spacing: 10
                        Text {
                            text: "󰕧"
                            color: root.sage
                            font.family: root.fonts.family
                            font.pixelSize: root.px(1.333)
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: "omaconvert"
                            color: root.fg
                            font.family: root.fontFamily
                            font.pixelSize: root.px(1)
                            font.bold: true
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: "v" + root.appVersion
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: root.px(1)
                            Accessible.name: "OmaConvert version " + root.appVersion
                        }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            readonly property string label: root.screen === "converting" ? "CONVERTING"
                                : (root.screen === "result" ? "READY"
                                : (service.metadata ? (root.inputKind === "image" ? "IMAGE" : "VIDEO") : ""))
                            readonly property color tone: root.screen === "converting" ? root.focusColor : root.mist
                            visible: label !== ""
                            implicitWidth: stateText.implicitWidth + 16
                            implicitHeight: stateText.implicitHeight + 4
                            color: root.alpha(tone, 0.13)
                            border.width: 1
                            border.color: tone
                            Text {
                                id: stateText
                                anchors.centerIn: parent
                                textFormat: Text.PlainText
                                text: parent.label
                                color: parent.tone
                                font.family: root.fontFamily
                                font.pixelSize: root.px(0.833)
                                font.bold: true
                                font.letterSpacing: 1.5
                            }
                        }
                        Ui.PanelActionButton {
                            iconText: "󰅖"
                            tooltipText: "Close  ·  Esc"
                            foreground: root.fg
                            hoverColor: root.urgent
                            Accessible.name: "Close OmaConvert"
                            onClicked: root.dismiss()
                        }
                    }
                }

                Flickable {
                    id: flick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: content.implicitHeight + 36
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height
                    ScrollBar.vertical: ScrollBar {
                        policy: flick.contentHeight > flick.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                        contentItem: Rectangle {
                            implicitWidth: 3
                            color: root.alpha(root.fg, 0.25)
                        }
                        background: Item {}
                    }

                    ColumnLayout {
                        id: content
                        x: Math.max(20, (flick.width - width) / 2)
                        y: 18
                        width: Math.min(flick.width - 40, root.maxContentWidth)
                        spacing: 16

                        // ── Source ────────────────────────────────────────
                        Item {
                            id: choose
                            visible: !service.result && root.screen !== "converting"
                            Layout.fillWidth: true
                            implicitHeight: service.inputPath ? sourceText.implicitHeight : emptyColumn.implicitHeight
                            enabled: !service.busy && !root.pickerBusy
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: service.inputPath ? "Change source file" : "Choose a video or image"
                            readonly property bool dragging: dropArea.containsDrag
                            readonly property bool hot: chooseMouse.containsMouse || dragging
                            Keys.onReturnPressed: root.chooseVideo()
                            Keys.onEnterPressed: root.chooseVideo()
                            Keys.onSpacePressed: root.chooseVideo()

                            // Loaded: the file as a title, its facts underneath.
                            RowLayout {
                                id: sourceText
                                visible: service.inputPath !== ""
                                width: parent.width
                                spacing: 12
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    SectionLabel { text: "SOURCE" }
                                    Text {
                                        textFormat: Text.PlainText
                                        Layout.fillWidth: true
                                        text: choose.dragging ? "Drop to open" : Model.name(service.inputPath)
                                        color: choose.activeFocus ? root.focusColor : root.fg
                                        font.family: root.fontFamily
                                        font.pixelSize: root.px(1.5)
                                        font.bold: true
                                        elide: Text.ElideMiddle
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        Layout.fillWidth: true
                                        text: service.metadata !== null ? Model.mediaDescription(service.metadata) : "Reading media…"
                                        color: root.dim
                                        font.family: root.fontFamily
                                        font.pixelSize: root.px(0.917)
                                        elide: Text.ElideRight
                                    }
                                }
                                Text {
                                    Layout.alignment: Qt.AlignBottom
                                    visible: !root.pickerBusy
                                    textFormat: Text.PlainText
                                    text: "change"
                                    color: choose.hot ? root.fg : root.faint
                                    font.family: root.fontFamily
                                    font.pixelSize: root.px(0.917)
                                }
                            }
                            // Empty: one big drop target.
                            ColumnLayout {
                                id: emptyColumn
                                visible: service.inputPath === ""
                                width: parent.width
                                spacing: 8
                                SectionLabel { text: "SOURCE" }
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 150
                                    color: choose.dragging ? root.alpha(root.sage, 0.18)
                                         : (choose.hot ? root.surface : "transparent")
                                    border.width: 1
                                    border.color: choose.activeFocus || choose.dragging ? root.focusColor : root.alpha(root.fg, 0.3)
                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        spacing: 8
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: root.pickerBusy ? "󰔟" : "󰇚"
                                            color: choose.activeFocus ? root.focusColor : root.sage
                                            font.family: root.fonts.family
                                            font.pixelSize: root.px(2.333)
                                        }
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            textFormat: Text.PlainText
                                            text: root.pickerBusy ? "Choosing file…" : (choose.dragging ? "Drop to open" : "Choose a video or image")
                                            color: root.fg
                                            font.family: root.fontFamily
                                            font.pixelSize: root.px(1.167)
                                            font.bold: true
                                        }
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            textFormat: Text.PlainText
                                            text: "⏎ browse  ·  or drop a file here"
                                            color: root.faint
                                            font.family: root.fontFamily
                                            font.pixelSize: root.px(0.917)
                                        }
                                    }
                                }
                            }
                            MouseArea {
                                id: chooseMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { choose.forceActiveFocus(); root.chooseVideo() }
                            }
                            DropArea {
                                id: dropArea
                                anchors.fill: parent
                                onDropped: drop => {
                                    if (!service.busy && drop.urls.length === 1) {
                                        var path = Model.localPath(drop.urls[0])
                                        if (path) { service.selectFile(path); drop.acceptProposedAction() }
                                    }
                                }
                            }
                        }
                        // Opt-in desktop entry; offered only before a file is chosen.
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: !service.inputPath && !service.result && service.openWith !== null
                            spacing: 4
                            ActionButton {
                                bordered: false
                                iconText: service.openWith && service.openWith.enabled ? "󰄲" : "󰄱"
                                text: "Show in Open With and app search"
                                selected: !!(service.openWith && service.openWith.enabled)
                                Accessible.name: "Show OmaConvert in Open With and app search"
                                onClicked: service.setOpenWith(!(service.openWith && service.openWith.enabled))
                            }
                            Hint {
                                visible: text !== ""
                                text: service.openWithError !== "" ? service.openWithError
                                    : "Adds OmaConvert to your file manager's Open With menu for videos and images. Default apps are not changed."
                                color: service.openWithError !== "" ? root.urgent : root.dim
                            }
                        }

                        // ── Preview + trim ────────────────────────────────
                        PreviewImage {
                            id: sourcePreview
                            Layout.fillWidth: true
                            visible: root.idleWithFile && (preview.sourceUrl !== "" || preview.sourceLoading)
                            title: "Preview"
                            showHeader: false
                            boxHeight: root.advanced ? 150 : Math.min(292, Math.round(width * 0.5625))
                            imageSource: preview.sourceUrl
                            loading: preview.sourceLoading
                            overlayText: root.trimShown ? Model.timeText(trimBar.playhead) : ""
                            overlayDot: root.urgent
                            badgeText: service.metadata ? (root.inputKind === "image" ? Model.dimensionsText(service.metadata.width, service.metadata.height)
                                : Math.min(service.metadata.width, service.metadata.height) + "p" + (Model.isHdr(service.metadata) ? "  ·  HDR" : "")) : ""
                            foreground: root.fg
                            background: root.bg
                            fontFamily: root.fontFamily
                            fontSize: root.fonts.body
                            Behavior on boxHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        }
                        TrimBar {
                            id: trimBar
                            Layout.fillWidth: true
                            visible: root.trimShown && root.idleWithFile
                            duration: (service.metadata && service.metadata.duration) || 0
                            trackColor: root.surface
                            fillColor: root.sage
                            knobColor: root.fg
                            knobBorderColor: root.bg
                            lineColor: root.line
                            playheadColor: root.focusColor
                            labelColor: root.mist
                            textColor: root.fg
                            urgentColor: root.urgent
                            fontFamily: root.fontFamily
                            fontSize: root.fonts.body
                            controlHeight: root.spacing.controlHeight
                            onScrubRequested: (position) => {
                                if (service.inputPath) preview.requestSource(service.inputPath, position)
                            }
                        }
                        SizeBudget {
                            Layout.fillWidth: true
                            visible: root.idleWithFile && root.activeLimit > 0 && (service.metadata.bytes || 0) > 0
                            fromBytes: (service.metadata && service.metadata.bytes) || 0
                            limitBytes: root.activeLimit
                            foreground: root.fg
                            fillColor: root.sage
                            limitColor: root.focusColor
                            fontFamily: root.fontFamily
                            fontSize: root.fonts.body
                        }

                        // ── Command line, recipes, all settings ──────────
                        // Recipes for this file, a line that understands
                        // "gif 30mb", and every field behind the settings
                        // button. Fields and the line stay in sync.
                        ColumnLayout {
                            id: output
                            Layout.fillWidth: true
                            visible: root.idleWithFile
                            spacing: 8
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Ui.TextField {
                                    id: commandInput
                                    Layout.fillWidth: true
                                    foreground: root.fg
                                    accent: root.accent
                                    horizontalPadding: root.spacing.controlPaddingX + root.px(1.5)
                                    font.family: root.fontFamily
                                    font.pixelSize: root.px(1.167)
                                    font.bold: true
                                    selectByMouse: true
                                    placeholderText: root.inputKind === "image" ? "webp  ·  png 500kb  ·  jpg" : "gif 30mb  ·  mp4 quick  ·  png frames 10fps"
                                    Accessible.name: "What to make, for example gif 30mb"
                                    onTextEdited: root.commandEdited()
                                    Keys.onUpPressed: event => { root.moveSelection(-1); event.accepted = true }
                                    Keys.onDownPressed: event => { root.moveSelection(1); event.accepted = true }
                                    Keys.onReturnPressed: event => root.commandReturn(event)
                                    Keys.onEnterPressed: event => root.commandReturn(event)
                                    Keys.onEscapePressed: event => {
                                        if (text === "") { event.accepted = false; return }
                                        text = ""
                                        root.commandEdited()
                                        event.accepted = true
                                    }
                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: root.spacing.controlPaddingX
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "❯"
                                        color: commandInput.activeFocus ? root.focusColor : root.faint
                                        font.family: root.fontFamily
                                        font.pixelSize: root.px(1.167)
                                        font.bold: true
                                    }
                                }
                                // Settings: full height of the line, square.
                                Rectangle {
                                    id: settingsButton
                                    Layout.preferredWidth: commandInput.height
                                    Layout.preferredHeight: commandInput.height
                                    color: root.advanced ? root.alpha(root.focusColor, 0.2)
                                         : (settingsMouse.containsMouse ? root.alpha(root.fg, 0.08) : root.surface)
                                    border.width: 1
                                    border.color: root.advanced || settingsButton.activeFocus ? root.focusColor : root.alpha(root.fg, 0.3)
                                    activeFocusOnTab: true
                                    Accessible.role: Accessible.Button
                                    Accessible.name: root.advanced ? "Back to recipes" : "All settings"
                                    Keys.onReturnPressed: root.toggleAdvanced()
                                    Keys.onEnterPressed: root.toggleAdvanced()
                                    Keys.onSpacePressed: root.toggleAdvanced()
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.advanced ? "󰅃" : "󰒓"
                                        color: root.advanced ? root.focusColor : root.fg
                                        font.family: root.fonts.family
                                        font.pixelSize: root.px(1.25)
                                    }
                                    MouseArea {
                                        id: settingsMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.toggleAdvanced()
                                    }
                                    Ui.PanelToolTip {
                                        visible: settingsMouse.containsMouse
                                        text: root.advanced ? "Back to recipes  ·  Ctrl+," : "All settings  ·  Ctrl+,"
                                    }
                                }
                            }
                            Flow {
                                Layout.fillWidth: true
                                visible: root.matched.chips.length > 0
                                spacing: 6
                                Text {
                                    textFormat: Text.PlainText
                                    text: "understood"
                                    color: root.faint
                                    font.family: root.fontFamily
                                    font.pixelSize: root.px(0.833)
                                    height: 20
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Repeater {
                                    model: root.matched.chips
                                    delegate: Rectangle {
                                        id: chip
                                        required property var modelData
                                        implicitWidth: chipText.implicitWidth + 14
                                        implicitHeight: 20
                                        color: chip.modelData.ok ? root.alpha(root.sage, 0.18) : "transparent"
                                        border.width: 1
                                        border.color: chip.modelData.ok ? root.alpha(root.sage, 0.56) : root.line
                                        Text {
                                            id: chipText
                                            anchors.centerIn: parent
                                            textFormat: Text.PlainText
                                            text: chip.modelData.text
                                            color: chip.modelData.ok ? root.mist : root.faint
                                            font.family: root.fontFamily
                                            font.pixelSize: root.px(0.833)
                                            font.strikeout: !chip.modelData.ok
                                        }
                                    }
                                }
                            }

                            // Recipes for this file, filtered by the command line.
                            ColumnLayout {
                                Layout.fillWidth: true
                                visible: !root.advanced
                                spacing: 0
                                Repeater {
                                    model: root.matched.rows
                                    delegate: Rectangle {
                                        id: recipeRow
                                        required property var modelData
                                        required property int index
                                        readonly property bool current: recipeRow.index === root.selectedRow
                                        readonly property bool blocked: recipeRow.modelData.problem !== ""
                                        Layout.fillWidth: true
                                        implicitHeight: recipeLine.implicitHeight + 18
                                        color: recipeRow.current ? root.alpha(root.focusColor, 0.08)
                                             : (recipeMouse.containsMouse ? root.surface : "transparent")
                                        Accessible.role: Accessible.Button
                                        Accessible.name: recipeRow.modelData.title + ". " + (recipeRow.modelData.problem || recipeRow.modelData.detail)
                                        Rectangle { visible: recipeRow.current; width: 2; height: parent.height; color: root.focusColor }
                                        Rectangle { visible: !recipeRow.current; anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.line }
                                        RowLayout {
                                            id: recipeLine
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.leftMargin: 14
                                            anchors.rightMargin: 14
                                            spacing: 14
                                            Text {
                                                textFormat: Text.PlainText
                                                text: recipeRow.index < 9 ? String(recipeRow.index + 1) : ""
                                                color: recipeRow.current ? root.focusColor : root.faint
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(0.917)
                                                font.bold: true
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                Layout.preferredWidth: root.px(3.5)
                                                text: (recipeRow.modelData.fields.format === Model.SEQUENCE ? "SEQ" : recipeRow.modelData.fields.format).toUpperCase()
                                                color: root.mist
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(0.833)
                                                font.bold: true
                                                font.letterSpacing: 1
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 2
                                                Text {
                                                    textFormat: Text.PlainText
                                                    Layout.fillWidth: true
                                                    text: recipeRow.modelData.title
                                                    color: root.fg
                                                    opacity: recipeRow.blocked ? 0.5 : 1
                                                    font.family: root.fontFamily
                                                    font.pixelSize: root.px(1.083)
                                                    font.bold: true
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    textFormat: Text.PlainText
                                                    Layout.fillWidth: true
                                                    text: recipeRow.modelData.problem || recipeRow.modelData.note || recipeRow.modelData.detail
                                                    color: recipeRow.blocked ? root.urgent : (recipeRow.modelData.note ? root.fg : root.dim)
                                                    font.family: root.fontFamily
                                                    font.pixelSize: root.px(0.833)
                                                    wrapMode: Text.WordWrap
                                                }
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                text: recipeRow.modelData.last ? "last used" : (recipeRow.modelData.custom ? "as typed" : "")
                                                visible: text !== ""
                                                color: recipeRow.current ? root.fg : root.faint
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(0.833)
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                text: "⏎"
                                                visible: recipeRow.current && !recipeRow.blocked
                                                color: root.focusColor
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(1.083)
                                                font.bold: true
                                            }
                                        }
                                        MouseArea {
                                            id: recipeMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: recipeRow.blocked ? Qt.ArrowCursor : Qt.PointingHandCursor
                                            onEntered: root.selectedRow = recipeRow.index
                                            onClicked: root.runRecipe(recipeRow.index)
                                        }
                                    }
                                }
                                Hint {
                                    Layout.topMargin: 6
                                    visible: text !== ""
                                    text: root.matched.note
                                    color: root.fg
                                }
                                Hint {
                                    Layout.topMargin: 6
                                    visible: root.outputFolder !== ""
                                    text: "saves to " + Model.folderLabel(root.outputFolder, root.homeDir)
                                }
                            }

                            // Every field; edits rewrite the command line.
                            Rectangle {
                                Layout.fillWidth: true
                                visible: root.advanced
                                implicitHeight: fields.implicitHeight + 2
                                color: root.alpha(root.fg, 0.02)
                                border.width: 1
                                border.color: root.line
                                ColumnLayout {
                                    id: fields
                                    x: 1
                                    y: 1
                                    width: parent.width - 2
                                    spacing: 0
                                    FieldRow {
                                        label: "FORMAT"
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Repeater {
                                                model: Model.formatGroups(root.inputKind, service.capabilities)
                                                delegate: Segments {
                                                    id: formatGroup
                                                    required property var modelData
                                                    options: formatGroup.modelData.items.map(item => ({ value: item, label: item === Model.SEQUENCE ? "SEQ" : item.toUpperCase() }))
                                                    value: formatGroup.modelData.items.indexOf(root.formatValue) >= 0 ? root.formatValue : ""
                                                    foreground: root.fg
                                                    selectedColor: root.sage
                                                    focusColor: root.focusColor
                                                    fontFamily: root.fontFamily
                                                    fontSize: root.px(0.917)
                                                    Accessible.name: formatGroup.modelData.title + " formats"
                                                    onChanged: v => { root.formatValue = v; root.syncCommand() }
                                                }
                                            }
                                        }
                                        Hint {
                                            text: root.unavailableFormats !== "" ? root.unavailableFormats
                                                : (root.inputKind === "image" ? "image formats" : "video formats  ·  stills  ·  SEQ = every frame as PNG")
                                            color: root.faint
                                            font.pixelSize: root.px(0.833)
                                        }
                                    }
                                    FieldRow {
                                        label: "MODE"
                                        enabled: root.formatValue !== Model.SEQUENCE
                                        Segments {
                                            options: [{ value: "0", label: "target size" }, { value: "1", label: "quick" }]
                                            value: String(root.modeIndex)
                                            foreground: root.fg
                                            selectedColor: root.sage
                                            focusColor: root.focusColor
                                            fontFamily: root.fontFamily
                                            fontSize: root.px(0.917)
                                            Accessible.name: "Conversion mode"
                                            onChanged: v => { root.modeIndex = Number(v); root.syncCommand() }
                                        }
                                    }
                                    FieldRow {
                                        label: "MAX SIZE"
                                        enabled: root.sizeShown
                                        RowLayout {
                                            spacing: 8
                                            Ui.TextField {
                                                id: sizeInput
                                                text: "50"
                                                Layout.preferredWidth: root.px(6.5)
                                                foreground: root.fg
                                                accent: root.accent
                                                font.family: root.fontFamily
                                                font.bold: true
                                                selectByMouse: true
                                                horizontalAlignment: TextInput.AlignRight
                                                Accessible.name: "Maximum file size"
                                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                                onTextEdited: root.syncCommand()
                                            }
                                            Segments {
                                                options: ["MB", "KB"]
                                                value: root.unitText
                                                foreground: root.fg
                                                selectedColor: root.sage
                                                focusColor: root.focusColor
                                                fontFamily: root.fontFamily
                                                fontSize: root.px(0.917)
                                                Accessible.name: "Size unit"
                                                onChanged: v => { root.unitIndex = v === "KB" ? 1 : 0; root.syncCommand() }
                                            }
                                        }
                                        // Common upload limits, one click each.
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            Text {
                                                textFormat: Text.PlainText
                                                text: "presets"
                                                color: root.faint
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(0.833)
                                                height: 18
                                                verticalAlignment: Text.AlignVCenter
                                            }
                                            Repeater {
                                                model: Model.SIZE_PRESETS
                                                delegate: Rectangle {
                                                    id: presetChip
                                                    required property var modelData
                                                    readonly property bool on: sizeInput.text === String(presetChip.modelData.size) && root.unitText === presetChip.modelData.unit
                                                    implicitWidth: presetText.implicitWidth + 12
                                                    implicitHeight: 18
                                                    color: presetMouse.containsMouse ? root.surface : "transparent"
                                                    border.width: 1
                                                    border.color: presetChip.on ? root.focusColor : root.alpha(root.fg, 0.15)
                                                    Text {
                                                        id: presetText
                                                        anchors.centerIn: parent
                                                        textFormat: Text.PlainText
                                                        text: presetChip.modelData.label
                                                        color: presetChip.on ? root.focusColor : root.dim
                                                        font.family: root.fontFamily
                                                        font.pixelSize: root.px(0.833)
                                                    }
                                                    MouseArea {
                                                        id: presetMouse
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: {
                                                            sizeInput.text = String(presetChip.modelData.size)
                                                            root.unitIndex = presetChip.modelData.unit === "KB" ? 1 : 0
                                                            root.syncCommand()
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        Hint {
                                            visible: !Model.validSize(sizeInput.text)
                                            text: "Enter a size greater than zero, for example 50 or 0.5."
                                            color: root.urgent
                                            font.pixelSize: root.px(0.833)
                                        }
                                    }
                                    FieldRow {
                                        label: "PREFER"
                                        enabled: root.sizeShown && root.formatValue === "GIF" && root.inputKind !== "image"
                                        Segments {
                                            options: [{ value: "0", label: "motion" }, { value: "1", label: "balanced" }, { value: "2", label: "detail" }]
                                            value: String(root.preferenceIndex)
                                            foreground: root.fg
                                            selectedColor: root.sage
                                            focusColor: root.focusColor
                                            fontFamily: root.fontFamily
                                            fontSize: root.px(0.917)
                                            Accessible.name: "Quality preference"
                                            onChanged: v => { root.preferenceIndex = Number(v); root.syncCommand() }
                                        }
                                        Hint {
                                            text: ["GIF only  ·  keep smooth motion, drop resolution first",
                                                   "GIF only  ·  trade resolution and frame rate evenly",
                                                   "GIF only  ·  keep a sharp picture, drop frames first"][root.preferenceIndex] || ""
                                            color: root.faint
                                            font.pixelSize: root.px(0.833)
                                        }
                                    }
                                    FieldRow {
                                        label: "QUALITY"
                                        visible: root.formatValue !== Model.SEQUENCE
                                        enabled: root.modeIndex === 1
                                        Segments {
                                            options: [{ value: "0", label: "small" }, { value: "1", label: "balanced" }, { value: "2", label: "high" }]
                                            value: String(root.presetIndex)
                                            foreground: root.fg
                                            selectedColor: root.sage
                                            focusColor: root.focusColor
                                            fontFamily: root.fontFamily
                                            fontSize: root.px(0.917)
                                            Accessible.name: "Quality preset"
                                            onChanged: v => { root.presetIndex = Number(v); root.syncCommand() }
                                        }
                                    }
                                    FieldRow {
                                        label: "FRAMES"
                                        visible: root.formatValue === Model.SEQUENCE
                                        Segments {
                                            options: [{ value: "0", label: "every" }, { value: "24", label: "24 fps" }, { value: "10", label: "10 fps" }, { value: "5", label: "5 fps" }, { value: "1", label: "1 fps" }]
                                            value: String(root.sequenceFps)
                                            foreground: root.fg
                                            selectedColor: root.sage
                                            focusColor: root.focusColor
                                            fontFamily: root.fontFamily
                                            fontSize: root.px(0.917)
                                            Accessible.name: "Frames per second to keep"
                                            onChanged: v => { root.sequenceFps = Number(v); root.syncCommand() }
                                        }
                                    }
                                    FieldRow {
                                        label: "SAVE TO"
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Text {
                                                text: "󰉋"
                                                color: root.mist
                                                font.family: root.fonts.family
                                                font.pixelSize: root.px(1.083)
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                Layout.fillWidth: true
                                                text: root.outputFolder ? Model.folderLabel(root.outputFolder, root.homeDir)
                                                    : (service.inputPath ? "next to source  ·  " + Model.folderLabel(Model.dirname(service.inputPath), root.homeDir) : "next to source")
                                                color: root.outputFolder ? root.fg : root.dim
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(1)
                                                font.bold: root.outputFolder !== ""
                                                elide: Text.ElideLeft
                                                Accessible.name: "Output folder: " + text
                                            }
                                            TextButton {
                                                label: folderPicker.running ? "choosing…" : "change"
                                                enabled: !root.pickerBusy
                                                onClicked: root.chooseFolder()
                                            }
                                            TextButton {
                                                visible: root.outputFolder !== ""
                                                label: "×"
                                                Accessible.name: "Save next to the source again"
                                                onClicked: root.setOutputFolder("")
                                            }
                                        }
                                        Row {
                                            spacing: 8
                                            activeFocusOnTab: true
                                            Accessible.role: Accessible.CheckBox
                                            Accessible.name: "Remember this folder"
                                            Keys.onSpacePressed: root.toggleRememberFolder()
                                            Rectangle {
                                                width: 11
                                                height: 11
                                                anchors.verticalCenter: parent.verticalCenter
                                                color: prefs.rememberFolder ? root.sage : "transparent"
                                                border.width: 1
                                                border.color: parent.activeFocus ? root.focusColor : (prefs.rememberFolder ? root.sage : root.alpha(root.fg, 0.4))
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                text: "remember this folder"
                                                color: root.dim
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(0.833)
                                                MouseArea {
                                                    anchors.fill: parent
                                                    anchors.leftMargin: -19
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.toggleRememberFolder()
                                                }
                                            }
                                        }
                                    }
                                    // What Enter will make, and the button that makes it.
                                    Rectangle {
                                        Layout.fillWidth: true
                                        implicitHeight: summaryRow.implicitHeight + 24
                                        color: root.alpha(root.focusColor, 0.06)
                                        RowLayout {
                                            id: summaryRow
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.leftMargin: 14
                                            anchors.rightMargin: 14
                                            spacing: 12
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 3
                                                SectionLabel { text: "WILL MAKE"; font.pixelSize: root.px(0.75) }
                                                Text {
                                                    textFormat: Text.PlainText
                                                    Layout.fillWidth: true
                                                    text: Model.outputName(service.inputPath, root.currentFields())
                                                    color: root.fg
                                                    font.family: root.fontFamily
                                                    font.pixelSize: root.px(1)
                                                    font.bold: true
                                                    elide: Text.ElideMiddle
                                                }
                                                Text {
                                                    textFormat: Text.PlainText
                                                    Layout.fillWidth: true
                                                    text: root.fieldsRecipe.problem || root.fieldsRecipe.note || root.fieldsRecipe.detail
                                                    color: root.fieldsRecipe.problem ? root.urgent : root.dim
                                                    font.family: root.fontFamily
                                                    font.pixelSize: root.px(0.833)
                                                    wrapMode: Text.WordWrap
                                                }
                                            }
                                            Rectangle {
                                                id: convertButton
                                                implicitWidth: convertRow.implicitWidth + 28
                                                implicitHeight: convertRow.implicitHeight + 18
                                                color: root.canConvert ? (convertMouse.pressed ? Qt.darker(root.focusColor, 1.15) : root.focusColor) : root.alpha(root.fg, 0.12)
                                                border.width: convertButton.activeFocus ? 2 : 0
                                                border.color: root.fg
                                                activeFocusOnTab: root.canConvert
                                                Accessible.role: Accessible.Button
                                                Accessible.name: "Convert"
                                                Keys.onReturnPressed: root.startConversion()
                                                Keys.onEnterPressed: root.startConversion()
                                                Keys.onSpacePressed: root.startConversion()
                                                Row {
                                                    id: convertRow
                                                    anchors.centerIn: parent
                                                    spacing: 8
                                                    Repeater {
                                                        model: ["⏎", "convert"]
                                                        delegate: Text {
                                                            required property string modelData
                                                            textFormat: Text.PlainText
                                                            text: modelData
                                                            color: root.canConvert ? root.bg : root.faint
                                                            font.family: root.fontFamily
                                                            font.pixelSize: root.px(1)
                                                            font.bold: true
                                                        }
                                                    }
                                                }
                                                MouseArea {
                                                    id: convertMouse
                                                    anchors.fill: parent
                                                    cursorShape: root.canConvert ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                    onClicked: root.startConversion()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ── Converting ────────────────────────────────────
                        ColumnLayout {
                            visible: root.screen === "converting"
                            Layout.fillWidth: true
                            spacing: 16
                            PreviewImage {
                                Layout.fillWidth: true
                                title: "Source"
                                showHeader: false
                                boxHeight: 200
                                dimmed: 0.55
                                imageSource: preview.sourceUrl
                                loading: preview.sourceLoading
                                foreground: root.fg
                                background: root.bg
                                fontFamily: root.fontFamily
                                fontSize: root.fonts.body
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                Text {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: Model.name(service.inputPath) + "  →  " + root.jobCommand
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.px(0.917)
                                    elide: Text.ElideMiddle
                                }
                                Text {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: service.cancelling ? "Cancelling…"
                                        : (service.phase.indexOf("Finding") === 0 ? "Finding the best quality that fits" : service.phase)
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.px(1.5)
                                    font.bold: true
                                    wrapMode: Text.WordWrap
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        textFormat: Text.PlainText
                                        Layout.fillWidth: true
                                        text: service.currentPass ? "pass " + service.currentPass : (service.phase.indexOf("Finding") === 0 ? "analysing samples" : "")
                                        color: root.mist
                                        font.family: root.fontFamily
                                        font.pixelSize: root.px(0.917)
                                        font.bold: true
                                    }
                                    Text {
                                        visible: !progressTrack.indeterminate
                                        text: Math.round(service.progress * 100) + "%"
                                        color: root.fg
                                        font.family: root.fontFamily
                                        font.pixelSize: root.px(0.917)
                                        font.bold: true
                                    }
                                }
                                Rectangle {
                                    id: progressTrack
                                    readonly property bool indeterminate: service.phase.indexOf("Finding") === 0
                                    Layout.fillWidth: true
                                    implicitHeight: 6
                                    color: root.alpha(root.fg, 0.08)
                                    clip: true
                                    Rectangle {
                                        visible: !progressTrack.indeterminate
                                        height: parent.height
                                        color: root.focusColor
                                        width: parent.width * Math.max(0, Math.min(1, service.progress))
                                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                    }
                                    Rectangle {
                                        id: sweep
                                        visible: progressTrack.indeterminate
                                        height: parent.height
                                        color: root.focusColor
                                        width: parent.width * 0.3
                                        NumberAnimation on x {
                                            running: sweep.visible && service.busy
                                            from: -sweep.width
                                            to: progressTrack.width
                                            duration: 1200
                                            loops: Animation.Infinite
                                            easing.type: Easing.InOutQuad
                                        }
                                    }
                                }
                            }
                            // Every size the search measured, against the limit.
                            ColumnLayout {
                                id: candList
                                Layout.fillWidth: true
                                visible: service.candidates.length > 0
                                spacing: 8
                                readonly property real span: Math.max(root.jobLimitBytes * 1.39,
                                    Math.max.apply(null, service.candidates.map(c => c.estimated_bytes || 0)), 1)
                                SectionLabel { text: "CANDIDATES" }
                                Repeater {
                                    model: service.candidates
                                    delegate: ColumnLayout {
                                        id: cand
                                        required property var modelData
                                        readonly property real bytes: cand.modelData.estimated_bytes || 0
                                        readonly property bool fits: root.jobLimitBytes <= 0 || cand.bytes <= root.jobLimitBytes
                                        Layout.fillWidth: true
                                        spacing: 4
                                        RowLayout {
                                            Layout.fillWidth: true
                                            Text {
                                                textFormat: Text.PlainText
                                                Layout.fillWidth: true
                                                text: cand.modelData.width + "×" + cand.modelData.height
                                                      + (cand.modelData.fps ? "  ·  " + Number(cand.modelData.fps).toFixed(1).replace(".0", "") + " fps" : "")
                                                      + (cand.modelData.colors ? "  ·  " + cand.modelData.colors + " col" : "")
                                                color: root.fg
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(0.917)
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                text: "≈ " + Model.compactSize(cand.bytes)
                                                color: cand.fits ? root.mist : root.urgent
                                                font.family: root.fontFamily
                                                font.pixelSize: root.px(0.917)
                                                font.bold: true
                                            }
                                        }
                                        Item {
                                            Layout.fillWidth: true
                                            implicitHeight: 10
                                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; color: root.alpha(root.fg, 0.06) }
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                height: 4
                                                width: parent.width * Math.min(1, cand.bytes / candList.span)
                                                color: cand.fits ? root.sage : root.urgent
                                            }
                                            Rectangle {
                                                visible: root.jobLimitBytes > 0
                                                x: parent.width * root.jobLimitBytes / candList.span
                                                width: 1
                                                height: 10
                                                color: root.fg
                                            }
                                        }
                                    }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 6
                                Text {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: Model.duration(Math.max(0, (root.clock - service.startedAt) / 1000)) + " elapsed"
                                    color: root.faint
                                    font.family: root.fontFamily
                                    font.pixelSize: root.px(0.917)
                                }
                                TextButton {
                                    key: "esc"
                                    label: service.cancelling ? "cancelling…" : "cancel"
                                    enabled: !service.cancelling
                                    onClicked: service.cancel()
                                }
                            }
                        }
                        // Reading a file: the phase on its own.
                        Hint {
                            visible: service.busy && root.screen !== "converting"
                            text: service.phase
                        }

                        // ── Result ────────────────────────────────────────
                        ResultView {
                            Layout.fillWidth: true
                            visible: root.screen === "result"
                            result: service.result || ({})
                            sourcePreview: preview.sourceUrl
                            resultPreview: preview.resultUrl
                            sourceLoading: preview.sourceLoading
                            resultLoading: preview.resultLoading
                            savings: (service.metadata && service.result) ? Model.savingsText(service.metadata.bytes, service.result.bytes) : ""
                            trimText: (service.result && service.result.trim_start !== undefined && service.metadata) ? Model.trimLabel(service.result.trim_start, service.result.trim_end, service.metadata.duration) : ""
                            sourceMeta: service.metadata ? Model.dimensionsText(service.metadata.width, service.metadata.height) + "  ·  " + Model.compactSize(service.metadata.bytes) : ""
                            resultMeta: service.result ? Model.dimensionsText(service.result.width, service.result.height) + "  ·  " + Model.compactSize(service.result.bytes) : ""
                            sourceBytes: (service.metadata && service.metadata.bytes) || 0
                            limitBytes: root.jobLimitBytes
                            foreground: root.fg
                            background: root.bg
                            accent: root.sage
                            okColor: root.mist
                            limitColor: root.focusColor
                            fontFamily: root.fontFamily
                            fontSize: root.fonts.body
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.screen === "result"
                            spacing: 0
                            ActionRow { primary: true; glyph: "󰈔"; key: "⏎"; label: service.result && service.result.kind === "sequence" ? "Open frames" : "Open file"; onTriggered: Qt.openUrlExternally(Model.fileUri(service.result.path)) }
                            ActionRow { glyph: "󰉋"; key: "o"; label: "Show in folder"; onTriggered: root.openResultFolder() }
                            ActionRow { glyph: "󰆏"; key: "c"; label: service.result && service.result.kind === "sequence" ? "Copy folder to clipboard" : "Copy file to clipboard"; onTriggered: root.copy(Model.fileUri(service.result.path) + "\r\n", true) }
                            ActionRow { glyph: "󰅍"; key: "p"; label: "Copy path"; onTriggered: root.copy(service.result.path, false) }
                            ActionRow { glyph: "󰐕"; key: "n"; label: "Convert another"; onTriggered: root.convertAnother() }
                        }

                        // ── Status ────────────────────────────────────────
                        Text {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            visible: root.staleInterface
                            text: "󰀪  Interface v" + root.appVersion + " is running, but v" + service.backendVersion
                                  + " is installed. Run `omarchy restart shell` to load the update."
                            color: root.urgent
                            font.family: root.fontFamily
                            font.pixelSize: root.fonts.bodySmall
                            wrapMode: Text.WordWrap
                        }
                        Hint { text: "󰄬  " + root.clipboardStatus; visible: root.clipboardStatus !== ""; color: root.fg }
                        Text {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            text: "󰅚  " + service.error
                            visible: service.error !== ""
                            color: root.urgent
                            font.family: root.fontFamily
                            font.pixelSize: root.fonts.body
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }
                        Hint { text: service.phase; visible: !service.busy && !service.result && text.indexOf("Cancelled") === 0; color: root.fg }
                        // The gifsicle tip only matters when a GIF is about to be made.
                        Hint { text: service.notice; visible: text !== "" && !service.busy && (text.indexOf("gifsicle") < 0 || (root.inputKind !== "image" && root.activeFormat === "GIF")) }
                        ActionButton {
                            id: detailsButton
                            property bool checked: false
                            visible: service.details !== ""
                            bordered: false
                            iconText: checked ? "󰅀" : "󰅂"
                            text: "Details"
                            onClicked: checked = !checked
                        }
                        TextArea {
                            Layout.fillWidth: true
                            Layout.maximumHeight: 120
                            visible: detailsButton.checked && service.details !== ""
                            text: service.details
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.WrapAnywhere
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: root.fonts.caption
                            background: Rectangle {
                                color: root.surface
                                border.width: 1
                                border.color: root.line
                            }
                        }
                    }
                }

                // ── Key bar: what the keys do right now ─────────────────
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: keyRow.implicitHeight + 14
                    color: root.alpha(root.fg, 0.03)
                    Rectangle { width: parent.width; height: 1; color: root.line }
                    RowLayout {
                        id: keyRow
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        spacing: 16
                        Repeater {
                            model: ({
                                empty: [["⏎", "browse"], ["drop", "a file"]],
                                recipes: [["↑↓", "choose"], ["⏎", "convert"], ["alt " + (root.matched.rows.length > 1 ? "1–" + Math.min(9, root.matched.rows.length) : "1"), "pick"], ["ctrl ,", "settings"]],
                                settings: [["tab", "next field"], ["←→", "choose"], ["ctrl ⏎", "convert"]],
                                converting: [],
                                result: [["⏎", "open"], ["o", "folder"], ["c", "copy"], ["p", "path"], ["n", "another"]]
                            })[root.screen] || []
                            delegate: Row {
                                id: keyHint
                                required property var modelData
                                spacing: 5
                                Text {
                                    textFormat: Text.PlainText
                                    text: keyHint.modelData[0]
                                    color: root.focusColor
                                    font.family: root.fontFamily
                                    font.pixelSize: root.px(0.833)
                                    font.bold: true
                                }
                                Text {
                                    textFormat: Text.PlainText
                                    text: keyHint.modelData[1]
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.px(0.833)
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            textFormat: Text.PlainText
                            text: root.screen === "settings" ? "esc back to recipes" : (root.screen === "converting" ? "esc cancel" : "esc close")
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: root.px(0.833)
                        }
                    }
                }
            }
        }
    }
}
