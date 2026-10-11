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
import "components/ui"
import qs.Commons as Commons

Item {
    id: root
    property var shell: null
    property var manifest: null
    property bool opened: false
    property bool closingFromHost: false
    readonly property var menuTheme: Commons.Color.menu
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
    // Components get it as one `theme` property.
    readonly property Theme theme: Theme {
        fg: root.menuTheme.text
        bg: root.menuTheme.background
        accent: Commons.Color.accent
        urgent: Commons.Color.urgent
        sage: Style.selectedStateColor(root.menuTheme.text, Commons.Color.accent, Commons.Color.urgent)
        mist: Style.hoverStateColor(root.menuTheme.text, Commons.Color.accent, Commons.Color.urgent)
        focus: Style.focusStateColor(root.menuTheme.text, Commons.Color.accent, Commons.Color.urgent)
        family: root.fonts.menuFamily
        iconFamily: root.fonts.family
        body: root.fonts.body
        bodySmall: root.fonts.bodySmall
        caption: root.fonts.caption
    }
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
    readonly property string unitText: ["MB", "KB"][root.unitIndex] || "MB"
    onFormatOptionsChanged: if (root.formatOptions.indexOf(root.formatValue) < 0) Qt.callLater(root.resetRecipes)
    Component.onCompleted: {
        if (prefs.rememberFolder) root.outputFolder = prefs.savedFolder
    }
    readonly property bool trimShown: !service.isBatch && service.metadata !== null && service.metadata.kind !== "image" && (service.metadata.duration || 0) > 0
    readonly property bool sizeShown: root.modeIndex === 0 && root.formatValue !== Model.SEQUENCE
    // Seconds that will be converted: the trimmed part of a video.
    readonly property real convertSeconds: root.trimShown ? Math.max(0, trimBar.endTime - trimBar.startTime) : ((service.metadata && service.metadata.duration) || 0)
    readonly property string lastCommand: root.inputKind === "image" ? prefs.lastImageCommand : prefs.lastVideoCommand
    // Without the trimmed length: dragging a trim handle must not rebuild
    // every recipe row. Rows work out their length-dependent texts.
    readonly property var matched: service.metadata
        ? Model.matchRecipes(commandInput.text, root.inputKind, service.metadata, service.capabilities, root.lastCommand, 0, root.pinned)
        : ({ rows: [], chips: [], note: "" })
    readonly property var fieldsRecipe: Model.recipe(root.currentFields(), root.inputKind, service.metadata, service.capabilities, root.convertSeconds)
    readonly property bool readyToConvert: !service.busy && !root.pickerBusy && service.metadata !== null && service.dependenciesReady && (!root.trimShown || trimBar.valid)
    // The same checks as a recipe row (sound, size, a known duration for a
    // size target), so the panel never starts what the list would block.
    readonly property bool canConvert: root.readyToConvert && root.fieldsRecipe.problem === "" && root.formatOptions.indexOf(root.formatValue) >= 0
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
        : (service.busy && (service.operation === "convert" || service.operation === "batch") ? "converting"
        : (root.idleWithFile ? (root.advanced ? "settings" : "recipes") : "empty"))
    readonly property bool canRunSelected: root.readyToConvert && root.selectedRow < root.matched.rows.length && root.matched.rows[root.selectedRow].problem === ""

    function open(payloadJson) {
        closingFromHost = false
        opened = true
        window.visible = true
        var payload = {}
        try { payload = JSON.parse(payloadJson || "{}") } catch (_) {}
        if (payload.files && payload.files.length) {
            var local = payload.files.map(f => Model.localPath(f)).filter(f => !!f)
            if (local.length) service.selectFiles(local)
            else service.error = "Choose local files, not remote URLs."
        } else if (payload.file) {
            var requestedPath = Model.localPath(payload.file)
            if (requestedPath) service.selectFile(requestedPath)
            else service.error = "Choose a local file, not a remote URL."
        }
        // Closing deleted the cached thumbnails; rebuild them for a file still open.
        if (service.metadata && service.inputPath && !payload.file && !(payload.files && payload.files.length)) {
            preview.requestSource(service.inputPath, root.trimShown ? trimBar.playhead : 0, false, service.metadata)
            if (service.result && service.result.path) preview.requestResult(service.result.first_frame || service.result.path)
        }
        service.loadStatus()
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
        var first = Model.recipes(root.inputKind, service.metadata, service.capabilities, root.lastCommand, root.convertSeconds, root.pinned)[0]
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
        // Thumbnails show file content: drop the cached copies with the window.
        preview.clearAll()
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
        if (service.isBatch) {
            service.convertBatch(sequence ? "png" : root.formatValue.toLowerCase(), root.sizeShown ? "target" : "quick",
                                 sizeInput.text, root.unitText, Model.PRESETS[root.presetIndex] || "balanced",
                                 Model.PREFERENCES[root.preferenceIndex] || "balanced", root.outputFolder,
                                 sequence ? root.sequenceFps : null)
            return
        }
        service.convert(sequence ? "png" : root.formatValue.toLowerCase(), root.sizeShown ? "target" : "quick",
                        sizeInput.text, root.unitText, Model.PRESETS[root.presetIndex] || "balanced",
                        Model.PREFERENCES[root.preferenceIndex] || "balanced",
                        useTrim ? trimBar.startTime : 0, useTrim ? trimBar.endTime : 0, root.outputFolder,
                        sequence ? root.sequenceFps : null)
    }
    // ── Pinned recipes: per kind, shown first ───────────────────────────
    readonly property var pinned: Model.parsePinned(root.inputKind === "image" ? prefs.pinnedImage : prefs.pinnedVideo)
    // The recipe Enter would run right now, as command words.
    readonly property string activeCommand: root.advanced ? Model.commandText(root.currentFields(), root.inputKind)
        : (root.selectedRow < root.matched.rows.length ? root.matched.rows[root.selectedRow].command : "")
    readonly property bool activePinned: root.activeCommand !== "" && root.pinned.indexOf(root.activeCommand) >= 0
    function togglePin() {
        if (!root.activeCommand) return
        var next = JSON.stringify(Model.togglePinned(root.pinned, root.activeCommand))
        if (root.inputKind === "image") prefs.pinnedImage = next
        else prefs.pinnedVideo = next
    }
    readonly property var batchReady: service.batch.filter(item => item.ok && item.status !== "skipped")
    readonly property real batchBytes: root.batchReady.reduce((sum, item) => sum + (item.bytes || 0), 0)
    readonly property int batchFinished: service.batch.filter(item => item.status === "done" || item.status === "failed" && item.ok).length
    readonly property real batchProgress: root.batchReady.length
        ? Math.min(1, (root.batchFinished + (service.batchCurrent >= 0 ? service.progress : 0)) / root.batchReady.length) : 0
    function batchTitle() {
        var n = root.batchReady.length
        var word = service.batchKind === "image" ? (n === 1 ? "image" : "images") : (n === 1 ? "video" : "videos")
        return n + " " + word + "  ·  " + Model.compactSize(root.batchBytes)
    }
    function batchNote() {
        var skipped = service.batch.filter(item => item.status === "skipped").length
        var unreadable = service.batch.filter(item => item.ok === false).length
        var parts = []
        if (skipped) parts.push(skipped + " skipped (other kind)")
        if (unreadable) parts.push(unreadable + " unreadable")
        return parts.join("  ·  ")
    }
    function batchFolder() {
        var paths = service.result && service.result.paths ? service.result.paths : []
        return paths.length ? Model.dirname(paths[0]) : ""
    }
    // ── Omarchy integration ─────────────────────────────────────────────
    property string pasteNote: ""
    // Ctrl+V: a screenshot or copied image becomes the source (saved under
    // ~/Pictures/OmaConvert), so do a copied file or a path; plain text goes
    // into the command line.
    function pasteFromClipboard() {
        if (service.busy || root.pickerBusy) return
        root.pasteNote = ""
        service.paste()
    }
    function prettyKeys(keys) {
        return String(keys || "").split(" + ").map(k => k === "PERIOD" ? "." : (k.length > 1 ? k[0] + k.slice(1).toLowerCase() : k)).join("+")
    }
    // Omarchy writes the recording's file name here while it records and
    // removes it once the video is finalized: the file going away is the end.
    property string activeRecording: ""
    function recordingEnded() {
        if (!root.activeRecording) return
        var file = root.activeRecording
        root.activeRecording = ""
        if (prefs.offerRecordings) Quickshell.execDetached(["python3", service.executable, "--offer-recording", file])
    }
    function convertAnother() {
        service.replaceBatch([])
        service.batchKind = ""
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
        // Pinned recipe commands as JSON arrays, e.g. ["jpg 150kb"].
        property string pinnedVideo: "[]"
        property string pinnedImage: "[]"
        property alias modeIndex: root.modeIndex
        property alias sizeText: sizeInput.text
        property alias unitIndex: root.unitIndex
        property alias preferenceIndex: root.preferenceIndex
        property alias presetIndex: root.presetIndex
        property bool rememberFolder: false
        property bool offerRecordings: true
        property string savedFolder: ""
    }
    ConvertService {
        id: service
        executable: Model.localPath(Qt.resolvedUrl("bin/omaconvert"))
        onMetadataChanged: {
            if (service.metadata && service.inputPath) {
                preview.clearResult()
                preview.requestSource(service.inputPath, undefined, false, service.metadata)
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
    Connections {
        target: service
        function onPasted(result) {
            if (result.kind === "file") service.selectFiles(result.paths && result.paths.length ? result.paths : [result.path])
            else if (result.kind === "text" && root.idleWithFile) {
                commandInput.insert(commandInput.cursorPosition, result.text)
                root.commandEdited()
                commandInput.forceActiveFocus()
            } else root.pasteNote = result.kind === "text"
                ? "The clipboard holds text, not a file or an image."
                : "Nothing to paste: copy an image, a screenshot or a file first."
        }
    }
    FileView {
        id: recordingMarker
        // Overridable so tests never touch the real marker.
        path: Quickshell.env("OMACONVERT_RECORDING_MARKER") || "/tmp/omarchy-screenrecord-filename"
        watchChanges: false
        printErrors: false
        onLoaded: { var name = text().trim(); if (name) root.activeRecording = name }
        onLoadFailed: root.recordingEnded()
    }
    Timer {
        interval: 2000
        repeat: true
        running: true
        onTriggered: recordingMarker.reload()
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
    // Native desktop picker via xdg portal (bin/omaconvert-pick keeps the
    // window's fullscreen state across the dialog). QML FileDialog inside a
    // layer-shell PanelWindow segfaults Qt (QQuickFileDialog::onShow ->
    // QQuickPopup::setPopupType); the external picker keeps the crash
    // out of the long-running shell process entirely.
    Process {
        id: filePicker
        command: [Model.localPath(Qt.resolvedUrl("bin/omaconvert-pick")), "--title", "Choose videos or images",
                  "--multiple", "--extensions", Model.pickerExtensions(service.capabilities)]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var paths = text.split("\n").map(line => root.pathFromUri(line)).filter(path => !!path)
                if (paths.length) service.selectFiles(paths)
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
        command: [Model.localPath(Qt.resolvedUrl("bin/omaconvert-pick")), "--title", "Choose where to save the result", "--directory"]
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

    // Quickshell creates FloatingWindow through its runtime platform factory.
    // qmllint disable uncreatable-type
    FloatingWindow {
        // qmllint enable uncreatable-type
        id: window
        title: "OmaConvert"
        // Quickshell windows default to visible: keep hidden until open().
        // Otherwise keepLoaded instantiation pops the window at every boot.
        visible: false
        color: root.theme.bg
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
            Rectangle { anchors.fill: parent; color: root.theme.bg }
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
                sequences: [StandardKey.Paste]
                enabled: root.opened && window.visible && !service.busy && root.screen !== "settings"
                context: Qt.WindowShortcut
                onActivated: root.pasteFromClipboard()
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
            Shortcut { sequences: ["Return", "Enter"]; enabled: root.screen === "result"; context: Qt.WindowShortcut; onActivated: Qt.openUrlExternally(Model.fileUri(service.isBatch ? root.batchFolder() : service.result.path)) }
            Shortcut { sequence: "O"; enabled: root.screen === "result"; context: Qt.WindowShortcut; onActivated: root.openResultFolder() }
            Shortcut { sequence: "C"; enabled: root.screen === "result"; context: Qt.WindowShortcut
                       onActivated: service.isBatch ? root.copy(service.result.paths.map(p => Model.fileUri(p)).join("\r\n") + "\r\n", true)
                                                    : root.copy(Model.fileUri(service.result.path) + "\r\n", true) }
            Shortcut { sequence: "P"; enabled: root.screen === "result"; context: Qt.WindowShortcut
                       onActivated: root.copy(service.isBatch ? service.result.paths.join("\n") : service.result.path, false) }
            Shortcut { sequence: "Ctrl+D"; enabled: root.screen === "recipes" || root.screen === "settings"; context: Qt.WindowShortcut; onActivated: root.togglePin() }
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
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.theme.line }
                    RowLayout {
                        id: titleRow
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 12
                        spacing: 10
                        Text {
                            text: "󰕧"
                            color: root.theme.sage
                            font.family: root.theme.iconFamily
                            font.pixelSize: root.theme.px(1.333)
                        }
                        MonoText {
                            theme: root.theme
                            text: "omaconvert"
                            font.bold: true
                        }
                        MonoText {
                            theme: root.theme
                            text: "v" + root.appVersion
                            color: root.theme.faint
                            Accessible.name: "OmaConvert version " + root.appVersion
                        }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            readonly property string label: root.screen === "converting" ? "CONVERTING"
                                : (root.screen === "result" ? "READY"
                                : (service.metadata ? (root.inputKind === "image" ? "IMAGE" : "VIDEO") : ""))
                            readonly property color tone: root.screen === "converting" ? root.theme.focus : root.theme.mist
                            visible: label !== ""
                            implicitWidth: stateText.implicitWidth + 16
                            implicitHeight: stateText.implicitHeight + 4
                            color: root.theme.alpha(tone, 0.13)
                            border.width: 1
                            border.color: tone
                            MonoText {
                                id: stateText
                                theme: root.theme
                                size: 0.833
                                anchors.centerIn: parent
                                text: parent.label
                                color: parent.tone
                                font.bold: true
                                font.letterSpacing: 1.5
                            }
                        }
                        Ui.PanelActionButton {
                            iconText: "󰅖"
                            tooltipText: "Close  ·  Esc"
                            foreground: root.theme.fg
                            hoverColor: root.theme.urgent
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
                            color: root.theme.alpha(root.theme.fg, 0.25)
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
                            visible: !service.result && root.screen !== "converting" && !service.isBatch
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
                                    SectionLabel { theme: root.theme; text: "SOURCE" }
                                    MonoText {
                                        theme: root.theme
                                        size: 1.5
                                        Layout.fillWidth: true
                                        text: choose.dragging ? "Drop to open" : Model.name(service.inputPath)
                                        color: choose.activeFocus ? root.theme.focus : root.theme.fg
                                        font.bold: true
                                        elide: Text.ElideMiddle
                                    }
                                    MonoText {
                                        theme: root.theme
                                        size: 0.917
                                        Layout.fillWidth: true
                                        text: service.metadata !== null ? Model.mediaDescription(service.metadata)
                                            : (service.busy ? "Reading media…" : "Not read  ·  choose another file")
                                        color: root.theme.dim
                                        elide: Text.ElideRight
                                    }
                                }
                                MonoText {
                                    theme: root.theme
                                    size: 0.917
                                    Layout.alignment: Qt.AlignBottom
                                    visible: !root.pickerBusy
                                    text: "change"
                                    color: choose.hot ? root.theme.fg : root.theme.faint
                                }
                            }
                            // Empty: one big drop target.
                            ColumnLayout {
                                id: emptyColumn
                                visible: service.inputPath === ""
                                width: parent.width
                                spacing: 8
                                SectionLabel { theme: root.theme; text: "SOURCE" }
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 150
                                    color: choose.dragging ? root.theme.alpha(root.theme.sage, 0.18)
                                         : (choose.hot ? root.theme.surface : "transparent")
                                    border.width: 1
                                    border.color: choose.activeFocus || choose.dragging ? root.theme.focus : root.theme.alpha(root.theme.fg, 0.3)
                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        spacing: 8
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: root.pickerBusy ? "󰔟" : "󰇚"
                                            color: choose.activeFocus ? root.theme.focus : root.theme.sage
                                            font.family: root.theme.iconFamily
                                            font.pixelSize: root.theme.px(2.333)
                                        }
                                        MonoText {
                                            theme: root.theme
                                            size: 1.167
                                            Layout.alignment: Qt.AlignHCenter
                                            text: root.pickerBusy ? "Choosing file…" : (choose.dragging ? "Drop to open" : "Choose a video or image")
                                            font.bold: true
                                        }
                                        MonoText {
                                            theme: root.theme
                                            size: 0.917
                                            Layout.alignment: Qt.AlignHCenter
                                            text: "⏎ browse  ·  drop a file  ·  ctrl+v paste"
                                            color: root.theme.faint
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
                                    if (service.busy) return
                                    var paths = drop.urls.map(url => Model.localPath(url)).filter(path => !!path)
                                    if (paths.length) { service.selectFiles(paths); drop.acceptProposedAction() }
                                }
                            }
                        }
                        // ── Batch: every file with its state ──────────────
                        ColumnLayout {
                            id: batchView
                            Layout.fillWidth: true
                            visible: service.isBatch
                            spacing: 6
                            RowLayout {
                                Layout.fillWidth: true
                                SectionLabel { theme: root.theme; text: "BATCH"; Layout.fillWidth: true }
                                MonoText {
                                    theme: root.theme
                                    size: 0.917
                                    visible: !service.busy && !service.result
                                    text: "change"
                                    color: batchChange.containsMouse ? root.theme.fg : root.theme.faint
                                    MouseArea {
                                        id: batchChange
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.chooseVideo()
                                    }
                                }
                            }
                            MonoText {
                                theme: root.theme
                                size: 1.5
                                Layout.fillWidth: true
                                text: root.batchReady.length ? root.batchTitle()
                                    : (service.busy ? "Reading " + service.batch.length + " files…" : "None of these files can be read")
                                font.bold: true
                            }
                            MonoText {
                                theme: root.theme
                                size: 0.917
                                Layout.fillWidth: true
                                // Always one line tall, so recipes do not move.
                                text: (root.idleWithFile ? "each file  →  " + (root.activeLimit > 0 ? "≤ " + Model.sizeLabel(root.activeLimit) : "quality preset") : "")
                                    + (root.batchNote() ? (root.idleWithFile ? "  ·  " : "") + root.batchNote() : "") || " "
                                color: root.theme.dim
                                elide: Text.ElideRight
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: Math.min(batchRows.implicitHeight, 8 * 30) + 2
                                color: "transparent"
                                border.width: 1
                                border.color: root.theme.line
                                clip: true
                                Flickable {
                                    id: batchFlick
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    contentHeight: batchRows.implicitHeight
                                    interactive: contentHeight > height
                                    boundsBehavior: Flickable.StopAtBounds
                                    // Keep the file being converted in view.
                                    contentY: service.batchCurrent < 0 ? contentY
                                        : Math.max(0, Math.min(contentHeight - height, service.batchCurrent * 30 - height / 2))
                                    Behavior on contentY { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                    Column {
                                        id: batchRows
                                        width: batchFlick.width
                                        Repeater {
                                            model: service.batchModel
                                            delegate: Rectangle {
                                                id: batchRow
                                                required property string path
                                                required property string status
                                                required property bool ok
                                                required property real bytes
                                                required property real outputBytes
                                                required property string message
                                                readonly property string phaseName: batchRow.status || "reading"
                                                width: batchRows.width
                                                height: 30
                                                color: batchRow.phaseName === "working" ? root.theme.alpha(root.theme.focus, 0.08) : "transparent"
                                                Rectangle { visible: batchRow.phaseName === "working"; width: 2; height: parent.height; color: root.theme.focus }
                                                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.theme.alpha(root.theme.fg, 0.06) }
                                                RowLayout {
                                                    anchors.fill: parent
                                                    anchors.leftMargin: 12
                                                    anchors.rightMargin: 12
                                                    spacing: 10
                                                    MonoText {
                                                        theme: root.theme
                                                        Layout.preferredWidth: root.theme.px(1)
                                                        text: ({ reading: "…", queued: "·", working: "▸", done: "✓", failed: "✗", skipped: "–", stopped: "■" })[batchRow.phaseName] || "·"
                                                        color: batchRow.phaseName === "done" ? root.theme.mist : (batchRow.phaseName === "failed" ? root.theme.urgent
                                                             : (batchRow.phaseName === "working" ? root.theme.focus : root.theme.faint))
                                                        font.bold: true
                                                    }
                                                    MonoText {
                                                        theme: root.theme
                                                        size: 0.917
                                                        Layout.fillWidth: true
                                                        text: Model.name(batchRow.path)
                                                        color: batchRow.phaseName === "skipped" || batchRow.phaseName === "failed" && !batchRow.ok ? root.theme.faint : root.theme.fg
                                                        elide: Text.ElideMiddle
                                                    }
                                                    MonoText {
                                                        theme: root.theme
                                                        size: 0.833
                                                        Layout.maximumWidth: batchRows.width * 0.48
                                                        text: batchRow.phaseName === "working" ? Math.round(service.progress * 100) + "%"
                                                            : batchRow.phaseName === "done" ? Model.compactSize(batchRow.bytes) + "  →  " + Model.compactSize(batchRow.outputBytes)
                                                            : batchRow.phaseName === "failed" || batchRow.phaseName === "skipped" ? (batchRow.message || batchRow.phaseName)
                                                            : batchRow.phaseName === "stopped" ? "stopped"
                                                            : batchRow.phaseName === "reading" ? "reading…"
                                                            : Model.compactSize(batchRow.bytes)
                                                        color: batchRow.phaseName === "failed" ? root.theme.urgent : (batchRow.phaseName === "done" ? root.theme.mist : root.theme.dim)
                                                        elide: Text.ElideRight
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        // Omarchy integration, offered before a file is chosen.
                        // Each switch is opt-in and undone the same way.
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: !service.inputPath && !service.result
                            spacing: 2
                            SectionLabel { theme: root.theme; text: "OMARCHY"; Layout.bottomMargin: 4 }
                            CheckRow {
                                theme: root.theme
                                visible: service.openWith !== null
                                checked: !!(service.openWith && service.openWith.enabled)
                                label: "Show in Open With and app search"
                                onToggled: service.setOpenWith(!checked)
                            }
                            CheckRow {
                                theme: root.theme
                                visible: !!(service.hotkey && service.hotkey.available && (service.hotkey.enabled || service.hotkey.free))
                                checked: !!(service.hotkey && service.hotkey.enabled)
                                label: "Hotkey"
                                detail: root.prettyKeys(service.hotkey ? (service.hotkey.keys || service.hotkey.free) : "")
                                onToggled: service.setHotkey(!checked)
                            }
                            CheckRow {
                                theme: root.theme
                                checked: prefs.offerRecordings
                                label: "Offer to shrink screen recordings over 10 MB"
                                onToggled: prefs.offerRecordings = !prefs.offerRecordings
                            }
                            Hint {
                                theme: root.theme
                                Layout.topMargin: 4
                                text: service.openWithError || service.hotkeyError
                                    || "The hotkey is a marked line in ~/.config/hypr/bindings.lua. A recording over 10 MB gets a notification that opens it here."
                                color: service.openWithError || service.hotkeyError ? root.theme.urgent : root.theme.faint
                            }
                        }

                        // ── Preview + trim ────────────────────────────────
                        PreviewImage {
                            id: sourcePreview
                            Layout.fillWidth: true
                            visible: root.idleWithFile && !service.isBatch && (preview.sourceUrl !== "" || preview.sourceLoading)
                            title: "Preview"
                            showHeader: false
                            boxHeight: root.advanced ? 150 : Math.min(292, Math.round(width * 0.5625))
                            imageSource: preview.sourceUrl
                            loading: preview.sourceLoading
                            overlayText: root.trimShown ? Model.timeText(trimBar.playhead) : ""
                            overlayDot: root.theme.urgent
                            badgeText: service.metadata ? (root.inputKind === "image" ? Model.dimensionsText(service.metadata.width, service.metadata.height)
                                : Math.min(service.metadata.width, service.metadata.height) + "p" + (Model.isHdr(service.metadata) ? "  ·  HDR" : "")) : ""
                            theme: root.theme
                            Behavior on boxHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        }
                        TrimBar {
                            id: trimBar
                            Layout.fillWidth: true
                            visible: root.trimShown && root.idleWithFile
                            duration: (service.metadata && service.metadata.duration) || 0
                            theme: root.theme
                            controlHeight: root.spacing.controlHeight
                            onScrubRequested: (position, draft) => {
                                if (service.inputPath) preview.requestSource(service.inputPath, position, draft, service.metadata)
                            }
                        }
                        SizeBudget {
                            Layout.fillWidth: true
                            // Always present with a file, so hovering recipes with
                            // and without a limit never shifts the list.
                            visible: root.idleWithFile && !service.isBatch && (service.metadata.bytes || 0) > 0
                            fromBytes: (service.metadata && service.metadata.bytes) || 0
                            limitBytes: root.activeLimit
                            theme: root.theme
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
                                    foreground: root.theme.fg
                                    accent: root.theme.accent
                                    horizontalPadding: root.spacing.controlPaddingX + root.theme.px(1.5)
                                    font.family: root.theme.family
                                    font.pixelSize: root.theme.px(1.167)
                                    font.bold: true
                                    selectByMouse: true
                                    placeholderText: root.inputKind === "image" ? "webp  ·  png 500kb  ·  jpg" : "gif 30mb  ·  mp4 quick  ·  png frames 10fps"
                                    Accessible.name: "What to make, for example gif 30mb"
                                    onTextEdited: root.commandEdited()
                                    Keys.onPressed: event => {
                                        if (event.matches(StandardKey.Paste)) { root.pasteFromClipboard(); event.accepted = true }
                                    }
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
                                        color: commandInput.activeFocus ? root.theme.focus : root.theme.faint
                                        font.family: root.theme.family
                                        font.pixelSize: root.theme.px(1.167)
                                        font.bold: true
                                    }
                                }
                                // Settings: full height of the line, square.
                                Rectangle {
                                    id: settingsButton
                                    Layout.preferredWidth: commandInput.height
                                    Layout.preferredHeight: commandInput.height
                                    color: root.advanced ? root.theme.alpha(root.theme.focus, 0.2)
                                         : (settingsMouse.containsMouse ? root.theme.alpha(root.theme.fg, 0.08) : root.theme.surface)
                                    border.width: 1
                                    border.color: root.advanced || settingsButton.activeFocus ? root.theme.focus : root.theme.alpha(root.theme.fg, 0.3)
                                    activeFocusOnTab: true
                                    Accessible.role: Accessible.Button
                                    Accessible.name: root.advanced ? "Back to recipes" : "All settings"
                                    Keys.onReturnPressed: root.toggleAdvanced()
                                    Keys.onEnterPressed: root.toggleAdvanced()
                                    Keys.onSpacePressed: root.toggleAdvanced()
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.advanced ? "󰅃" : "󰒓"
                                        color: root.advanced ? root.theme.focus : root.theme.fg
                                        font.family: root.theme.iconFamily
                                        font.pixelSize: root.theme.px(1.25)
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
                            // Always one row tall: typing never pushes the list down.
                            Flow {
                                Layout.fillWidth: true
                                spacing: 6
                                MonoText {
                                    theme: root.theme
                                    size: 0.833
                                    text: root.matched.chips.length > 0 ? "understood"
                                        : (root.inputKind === "image" ? "type a format and size  ·  jpg 200kb  ·  webp" : "type a format and size  ·  gif 10mb  ·  mp4 quick")
                                    color: root.theme.faint
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
                                        color: chip.modelData.ok ? root.theme.alpha(root.theme.sage, 0.18) : "transparent"
                                        border.width: 1
                                        border.color: chip.modelData.ok ? root.theme.alpha(root.theme.sage, 0.56) : root.theme.line
                                        MonoText {
                                            id: chipText
                                            theme: root.theme
                                            size: 0.833
                                            anchors.centerIn: parent
                                            text: chip.modelData.text
                                            color: chip.modelData.ok ? root.theme.mist : root.theme.faint
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
                                        readonly property string detail: Model.recipeDetail(recipeRow.modelData.fields, root.inputKind, service.metadata, root.convertSeconds)
                                        readonly property string note: Model.recipeNote(recipeRow.modelData.fields, root.inputKind, root.convertSeconds)
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
                                            onPositionChanged: if (root.selectedRow !== recipeRow.index) root.selectedRow = recipeRow.index
                                            onClicked: root.runRecipe(recipeRow.index)
                                        }
                                    }
                                }
                                Hint {
                                    theme: root.theme
                                    Layout.topMargin: 6
                                    visible: text !== ""
                                    text: root.matched.note
                                    color: root.theme.fg
                                }
                                Hint {
                                    theme: root.theme
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
                                color: root.theme.alpha(root.theme.fg, 0.02)
                                border.width: 1
                                border.color: root.theme.line
                                ColumnLayout {
                                    id: fields
                                    x: 1
                                    y: 1
                                    width: parent.width - 2
                                    spacing: 0
                                    FieldRow {
                                        theme: root.theme
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
                                                    theme: root.theme
                                                    Accessible.name: formatGroup.modelData.title + " formats"
                                                    onChanged: v => { root.formatValue = v; root.syncCommand() }
                                                }
                                            }
                                        }
                                        Hint {
                                            theme: root.theme
                                            text: root.unavailableFormats !== "" ? root.unavailableFormats
                                                : (root.inputKind === "image" ? "image formats" : "video formats  ·  stills  ·  SEQ = every frame as PNG")
                                            color: root.theme.faint
                                            font.pixelSize: root.theme.px(0.833)
                                        }
                                    }
                                    FieldRow {
                                        theme: root.theme
                                        label: "MODE"
                                        enabled: root.formatValue !== Model.SEQUENCE
                                        Segments {
                                            options: [{ value: "0", label: "target size" }, { value: "1", label: "quick" }]
                                            value: String(root.modeIndex)
                                            theme: root.theme
                                            Accessible.name: "Conversion mode"
                                            onChanged: v => { root.modeIndex = Number(v); root.syncCommand() }
                                        }
                                    }
                                    FieldRow {
                                        theme: root.theme
                                        label: "MAX SIZE"
                                        enabled: root.sizeShown
                                        RowLayout {
                                            spacing: 8
                                            Ui.TextField {
                                                id: sizeInput
                                                text: "50"
                                                Layout.preferredWidth: root.theme.px(6.5)
                                                foreground: root.theme.fg
                                                accent: root.theme.accent
                                                font.family: root.theme.family
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
                                                theme: root.theme
                                                Accessible.name: "Size unit"
                                                onChanged: v => { root.unitIndex = v === "KB" ? 1 : 0; root.syncCommand() }
                                            }
                                        }
                                        // Common upload limits, one click each.
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            MonoText {
                                                theme: root.theme
                                                size: 0.833
                                                text: "presets"
                                                color: root.theme.faint
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
                                                    color: presetMouse.containsMouse ? root.theme.surface : "transparent"
                                                    border.width: 1
                                                    border.color: presetChip.on ? root.theme.focus : root.theme.alpha(root.theme.fg, 0.15)
                                                    MonoText {
                                                        id: presetText
                                                        theme: root.theme
                                                        size: 0.833
                                                        anchors.centerIn: parent
                                                        text: presetChip.modelData.label
                                                        color: presetChip.on ? root.theme.focus : root.theme.dim
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
                                            theme: root.theme
                                            visible: !Model.validSize(sizeInput.text)
                                            text: "Enter a size greater than zero, for example 50 or 0.5."
                                            color: root.theme.urgent
                                            font.pixelSize: root.theme.px(0.833)
                                        }
                                    }
                                    FieldRow {
                                        theme: root.theme
                                        label: "PREFER"
                                        enabled: root.sizeShown && root.formatValue === "GIF" && root.inputKind !== "image"
                                        Segments {
                                            options: [{ value: "0", label: "motion" }, { value: "1", label: "balanced" }, { value: "2", label: "detail" }]
                                            value: String(root.preferenceIndex)
                                            theme: root.theme
                                            Accessible.name: "Quality preference"
                                            onChanged: v => { root.preferenceIndex = Number(v); root.syncCommand() }
                                        }
                                        Hint {
                                            theme: root.theme
                                            text: ["GIF only  ·  keep smooth motion, drop resolution first",
                                                   "GIF only  ·  trade resolution and frame rate evenly",
                                                   "GIF only  ·  keep a sharp picture, drop frames first"][root.preferenceIndex] || ""
                                            color: root.theme.faint
                                            font.pixelSize: root.theme.px(0.833)
                                        }
                                    }
                                    FieldRow {
                                        theme: root.theme
                                        label: "QUALITY"
                                        visible: root.formatValue !== Model.SEQUENCE
                                        enabled: root.modeIndex === 1
                                        Segments {
                                            options: [{ value: "0", label: "small" }, { value: "1", label: "balanced" }, { value: "2", label: "high" }]
                                            value: String(root.presetIndex)
                                            theme: root.theme
                                            Accessible.name: "Quality preset"
                                            onChanged: v => { root.presetIndex = Number(v); root.syncCommand() }
                                        }
                                    }
                                    FieldRow {
                                        theme: root.theme
                                        label: "FRAMES"
                                        visible: root.formatValue === Model.SEQUENCE
                                        Segments {
                                            options: [{ value: "0", label: "every" }, { value: "24", label: "24 fps" }, { value: "10", label: "10 fps" }, { value: "5", label: "5 fps" }, { value: "1", label: "1 fps" }]
                                            value: String(root.sequenceFps)
                                            theme: root.theme
                                            Accessible.name: "Frames per second to keep"
                                            onChanged: v => { root.sequenceFps = Number(v); root.syncCommand() }
                                        }
                                    }
                                    FieldRow {
                                        theme: root.theme
                                        label: "SAVE TO"
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Text {
                                                text: "󰉋"
                                                color: root.theme.mist
                                                font.family: root.theme.iconFamily
                                                font.pixelSize: root.theme.px(1.083)
                                            }
                                            MonoText {
                                                theme: root.theme
                                                Layout.fillWidth: true
                                                text: root.outputFolder ? Model.folderLabel(root.outputFolder, root.homeDir)
                                                    : (service.inputPath ? "next to source  ·  " + Model.folderLabel(Model.dirname(service.inputPath), root.homeDir) : "next to source")
                                                color: root.outputFolder ? root.theme.fg : root.theme.dim
                                                font.bold: root.outputFolder !== ""
                                                elide: Text.ElideLeft
                                                Accessible.name: "Output folder: " + text
                                            }
                                            TextButton {
                                                theme: root.theme
                                                label: folderPicker.running ? "choosing…" : "change"
                                                enabled: !root.pickerBusy
                                                onClicked: root.chooseFolder()
                                            }
                                            TextButton {
                                                theme: root.theme
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
                                                color: prefs.rememberFolder ? root.theme.sage : "transparent"
                                                border.width: 1
                                                border.color: parent.activeFocus ? root.theme.focus : (prefs.rememberFolder ? root.theme.sage : root.theme.alpha(root.theme.fg, 0.4))
                                            }
                                            MonoText {
                                                theme: root.theme
                                                size: 0.833
                                                text: "remember this folder"
                                                color: root.theme.dim
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
                                        color: root.theme.alpha(root.theme.focus, 0.06)
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
                                                SectionLabel { theme: root.theme; text: "WILL MAKE"; font.pixelSize: root.theme.px(0.75) }
                                                MonoText {
                                                    theme: root.theme
                                                    Layout.fillWidth: true
                                                    text: Model.outputName(service.inputPath, root.currentFields())
                                                    font.bold: true
                                                    elide: Text.ElideMiddle
                                                }
                                                MonoText {
                                                    theme: root.theme
                                                    size: 0.833
                                                    Layout.fillWidth: true
                                                    text: root.fieldsRecipe.problem || root.fieldsRecipe.note || root.fieldsRecipe.detail
                                                    color: root.fieldsRecipe.problem ? root.theme.urgent : root.theme.dim
                                                    wrapMode: Text.WordWrap
                                                }
                                            }
                                            TextButton {
                                                theme: root.theme
                                                key: "★"
                                                label: root.activePinned ? "unpin" : "pin"
                                                Accessible.name: root.activePinned ? "Unpin this recipe" : "Pin this recipe to the top of the list"
                                                onClicked: root.togglePin()
                                            }
                                            Rectangle {
                                                id: convertButton
                                                implicitWidth: convertRow.implicitWidth + 28
                                                implicitHeight: convertRow.implicitHeight + 18
                                                color: root.canConvert ? (convertMouse.pressed ? Qt.darker(root.theme.focus, 1.15) : root.theme.focus) : root.theme.alpha(root.theme.fg, 0.12)
                                                border.width: convertButton.activeFocus ? 2 : 0
                                                border.color: root.theme.fg
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
                                                        delegate: MonoText {
                                                            theme: root.theme
                                                            required property string modelData
                                                            text: modelData
                                                            color: root.canConvert ? root.theme.bg : root.theme.faint
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
                                visible: !service.isBatch
                                title: "Source"
                                showHeader: false
                                boxHeight: 200
                                dimmed: 0.55
                                imageSource: preview.sourceUrl
                                loading: preview.sourceLoading
                                theme: root.theme
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                MonoText {
                                    theme: root.theme
                                    size: 0.917
                                    Layout.fillWidth: true
                                    text: (service.isBatch ? root.batchReady.length + " files" : Model.name(service.inputPath)) + "  →  " + root.jobCommand
                                    color: root.theme.dim
                                    elide: Text.ElideMiddle
                                }
                                MonoText {
                                    theme: root.theme
                                    size: 1.5
                                    Layout.fillWidth: true
                                    text: service.cancelling ? "Cancelling…"
                                        : service.isBatch ? "File " + Math.min(root.batchReady.length, root.batchFinished + 1) + " of " + root.batchReady.length
                                        : (service.phase.indexOf("Finding") === 0 ? "Finding the best quality that fits" : service.phase)
                                    font.bold: true
                                    wrapMode: Text.WordWrap
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                RowLayout {
                                    Layout.fillWidth: true
                                    MonoText {
                                        theme: root.theme
                                        size: 0.917
                                        Layout.fillWidth: true
                                        text: service.isBatch ? (service.batchCurrent >= 0 ? Model.name(service.batch[service.batchCurrent].path) : "")
                                            : service.currentPass ? "pass " + service.currentPass : (service.phase.indexOf("Finding") === 0 ? "analysing samples" : "")
                                        color: root.theme.mist
                                        font.bold: true
                                    }
                                    Text {
                                        visible: !progressTrack.indeterminate
                                        text: Math.round((service.isBatch ? root.batchProgress : service.progress) * 100) + "%"
                                        color: root.theme.fg
                                        font.family: root.theme.family
                                        font.pixelSize: root.theme.px(0.917)
                                        font.bold: true
                                    }
                                }
                                Rectangle {
                                    id: progressTrack
                                    readonly property bool indeterminate: !service.isBatch && service.phase.indexOf("Finding") === 0
                                    Layout.fillWidth: true
                                    implicitHeight: 6
                                    color: root.theme.alpha(root.theme.fg, 0.08)
                                    clip: true
                                    Rectangle {
                                        visible: !progressTrack.indeterminate
                                        height: parent.height
                                        color: root.theme.focus
                                        width: parent.width * Math.max(0, Math.min(1, service.isBatch ? root.batchProgress : service.progress))
                                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                    }
                                    Rectangle {
                                        id: sweep
                                        visible: progressTrack.indeterminate
                                        height: parent.height
                                        color: root.theme.focus
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
                                SectionLabel { theme: root.theme; text: "CANDIDATES" }
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
                                            MonoText {
                                                theme: root.theme
                                                size: 0.917
                                                Layout.fillWidth: true
                                                text: cand.modelData.width + "×" + cand.modelData.height
                                                      + (cand.modelData.fps ? "  ·  " + Number(cand.modelData.fps).toFixed(1).replace(".0", "") + " fps" : "")
                                                      + (cand.modelData.colors ? "  ·  " + cand.modelData.colors + " col" : "")
                                                elide: Text.ElideRight
                                            }
                                            MonoText {
                                                theme: root.theme
                                                size: 0.917
                                                text: "≈ " + Model.compactSize(cand.bytes)
                                                color: cand.fits ? root.theme.mist : root.theme.urgent
                                                font.bold: true
                                            }
                                        }
                                        Item {
                                            Layout.fillWidth: true
                                            implicitHeight: 10
                                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; color: root.theme.alpha(root.theme.fg, 0.06) }
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                height: 4
                                                width: parent.width * Math.min(1, cand.bytes / candList.span)
                                                color: cand.fits ? root.theme.sage : root.theme.urgent
                                            }
                                            Rectangle {
                                                visible: root.jobLimitBytes > 0
                                                x: parent.width * root.jobLimitBytes / candList.span
                                                width: 1
                                                height: 10
                                                color: root.theme.fg
                                            }
                                        }
                                    }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 6
                                MonoText {
                                    theme: root.theme
                                    size: 0.917
                                    Layout.fillWidth: true
                                    text: Model.duration(Math.max(0, (root.clock - service.startedAt) / 1000)) + " elapsed"
                                    color: root.theme.faint
                                }
                                TextButton {
                                    theme: root.theme
                                    key: "esc"
                                    label: service.cancelling ? "cancelling…" : "cancel"
                                    enabled: !service.cancelling
                                    onClicked: service.cancel()
                                }
                            }
                        }
                        // Reading a file: the phase on its own.
                        Hint {
                            theme: root.theme
                            visible: service.busy && root.screen !== "converting"
                            text: service.phase
                        }

                        // ── Result ────────────────────────────────────────
                        ResultView {
                            Layout.fillWidth: true
                            visible: root.screen === "result" && !service.isBatch
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
                            theme: root.theme
                        }
                        // Batch summary: the sizes before and after, what failed.
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.screen === "result" && service.isBatch
                            spacing: 4
                            RowLayout {
                                spacing: 10
                                MonoText {
                                    theme: root.theme
                                    size: 3.6
                                    text: service.result ? Model.compactSize(service.result.bytes_after) : ""
                                    font.bold: true
                                }
                                Rectangle {
                                    Layout.alignment: Qt.AlignBottom
                                    Layout.bottomMargin: 8
                                    implicitWidth: batchBadge.implicitWidth + 16
                                    implicitHeight: batchBadge.implicitHeight + 6
                                    color: root.theme.alpha(root.theme.sage, 0.22)
                                    border.width: 1
                                    border.color: root.theme.sage
                                    MonoText {
                                        id: batchBadge
                                        theme: root.theme
                                        size: 0.917
                                        anchors.centerIn: parent
                                        text: service.result ? "✓ " + service.result.done + " of " + service.result.total + " done" : ""
                                        color: root.theme.mist
                                        font.bold: true
                                    }
                                }
                            }
                            MonoText {
                                theme: root.theme
                                size: 0.917
                                Layout.fillWidth: true
                                text: service.result ? Model.savingsText(service.result.bytes_before, service.result.bytes_after)
                                    + (service.result.failed ? "  ·  " + service.result.failed + " failed" : "") : ""
                                color: service.result && service.result.failed ? root.theme.urgent : root.theme.faint
                                wrapMode: Text.WordWrap
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.screen === "result" && service.isBatch
                            spacing: 0
                            ActionRow { theme: root.theme; primary: true; glyph: "󰉋"; key: "⏎"; label: "Open the folder"; onTriggered: Qt.openUrlExternally(Model.fileUri(root.batchFolder())) }
                            ActionRow { theme: root.theme; glyph: "󰆏"; key: "c"; label: "Copy all files to clipboard"; onTriggered: root.copy(service.result.paths.map(p => Model.fileUri(p)).join("\r\n") + "\r\n", true) }
                            ActionRow { theme: root.theme; glyph: "󰅍"; key: "p"; label: "Copy all paths"; onTriggered: root.copy(service.result.paths.join("\n"), false) }
                            ActionRow { theme: root.theme; glyph: "󰐕"; key: "n"; label: "Convert more"; onTriggered: root.convertAnother() }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.screen === "result" && !service.isBatch
                            spacing: 0
                            ActionRow { theme: root.theme; primary: true; glyph: "󰈔"; key: "⏎"; label: service.result && service.result.kind === "sequence" ? "Open frames" : "Open file"; onTriggered: Qt.openUrlExternally(Model.fileUri(service.result.path)) }
                            ActionRow { theme: root.theme; glyph: "󰉋"; key: "o"; label: "Show in folder"; onTriggered: root.openResultFolder() }
                            ActionRow { theme: root.theme; glyph: "󰆏"; key: "c"; label: service.result && service.result.kind === "sequence" ? "Copy folder to clipboard" : "Copy file to clipboard"; onTriggered: root.copy(Model.fileUri(service.result.path) + "\r\n", true) }
                            ActionRow { theme: root.theme; glyph: "󰅍"; key: "p"; label: "Copy path"; onTriggered: root.copy(service.result.path, false) }
                            ActionRow { theme: root.theme; glyph: "󰐕"; key: "n"; label: "Convert another"; onTriggered: root.convertAnother() }
                        }

                        // ── Status ────────────────────────────────────────
                        Text {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            visible: root.staleInterface
                            text: "󰀪  Interface v" + root.appVersion + " is running, but v" + service.backendVersion
                                  + " is installed. Run `omarchy restart shell` to load the update."
                            color: root.theme.urgent
                            font.family: root.theme.family
                            font.pixelSize: root.theme.bodySmall
                            wrapMode: Text.WordWrap
                        }
                        Hint { theme: root.theme; text: "󰄬  " + root.clipboardStatus; visible: root.clipboardStatus !== ""; color: root.theme.fg }
                        Hint { theme: root.theme; text: root.pasteNote; visible: root.pasteNote !== "" && !service.busy; color: root.theme.fg }
                        MonoText {
                            theme: root.theme
                            Layout.fillWidth: true
                            text: "󰅚  " + service.error
                            visible: service.error !== ""
                            color: root.theme.urgent
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }
                        Hint { theme: root.theme; text: service.phase; visible: !service.busy && !service.result && text.indexOf("Cancelled") === 0; color: root.theme.fg }
                        // The gifsicle tip only matters when a GIF is about to be made.
                        Hint { theme: root.theme; text: service.notice; visible: text !== "" && !service.busy && (text.indexOf("gifsicle") < 0 || (root.inputKind !== "image" && root.activeFormat === "GIF")) }
                        Ui.Button {
                            id: detailsButton
                            property bool checked: false
                            visible: service.details !== ""
                            bordered: false
                            focusable: true
                            foreground: root.theme.fg
                            accent: root.theme.accent
                            fontFamily: root.theme.family
                            opacity: enabled ? 1 : 0.4
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
                            color: root.theme.dim
                            font.family: root.theme.family
                            font.pixelSize: root.theme.caption
                            background: Rectangle {
                                color: root.theme.surface
                                border.width: 1
                                border.color: root.theme.line
                            }
                        }
                    }
                }

                // ── Key bar: what the keys do right now ─────────────────
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: keyRow.implicitHeight + 14
                    color: root.theme.alpha(root.theme.fg, 0.03)
                    Rectangle { width: parent.width; height: 1; color: root.theme.line }
                    RowLayout {
                        id: keyRow
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        spacing: 16
                        Repeater {
                            model: ({
                                empty: [["⏎", "browse"], ["ctrl v", "paste"], ["drop", "a file"]],
                                recipes: [["↑↓", "choose"], ["⏎", "convert"], ["alt " + (root.matched.rows.length > 1 ? "1–" + Math.min(9, root.matched.rows.length) : "1"), "pick"], ["ctrl d", root.activePinned ? "unpin" : "pin"], ["ctrl ,", "settings"]],
                                settings: [["tab", "next field"], ["←→", "choose"], ["ctrl d", root.activePinned ? "unpin" : "pin"], ["ctrl ⏎", "convert"]],
                                converting: [],
                                result: service.isBatch ? [["⏎", "folder"], ["c", "copy all"], ["p", "paths"], ["n", "more"]]
                                    : [["⏎", "open"], ["o", "folder"], ["c", "copy"], ["p", "path"], ["n", "another"]]
                            })[root.screen] || []
                            delegate: Row {
                                id: keyHint
                                required property var modelData
                                spacing: 5
                                MonoText {
                                    theme: root.theme
                                    size: 0.833
                                    text: keyHint.modelData[0]
                                    color: root.theme.focus
                                    font.bold: true
                                }
                                MonoText {
                                    theme: root.theme
                                    size: 0.833
                                    text: keyHint.modelData[1]
                                    color: root.theme.dim
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        MonoText {
                            theme: root.theme
                            size: 0.833
                            text: root.screen === "settings" ? "esc back to recipes" : (root.screen === "converting" ? "esc cancel" : "esc close")
                            color: root.theme.faint
                        }
                    }
                }
            }
        }
    }
}
