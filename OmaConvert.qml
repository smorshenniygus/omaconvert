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
    readonly property color fg: root.menuTheme.text
    readonly property color dim: Qt.darker(root.fg, 1.4)
    readonly property color accent: Color.accent
    readonly property color urgent: Color.urgent
    readonly property string fontFamily: root.fonts.menuFamily
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

    // Small building blocks so every row reads like a first-party panel.
    component FieldLabel: Text {
        readonly property var menuTheme: Color.menu
        readonly property var fontTokens: Style.font
        textFormat: Text.PlainText
        color: Qt.darker(menuTheme.text, 1.4)
        font.family: fontTokens.menuFamily
        font.pixelSize: fontTokens.bodySmall
        font.bold: true
        Layout.preferredWidth: Style.space(104)
        Layout.alignment: Qt.AlignVCenter
        elide: Text.ElideRight
    }
    component Hint: Text {
        readonly property var menuTheme: Color.menu
        readonly property var fontTokens: Style.font
        textFormat: Text.PlainText
        Layout.fillWidth: true
        color: Qt.darker(menuTheme.text, 1.4)
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

    // Quickshell creates FloatingWindow through its runtime platform factory.
    // qmllint disable uncreatable-type
    FloatingWindow {
        // qmllint enable uncreatable-type
        id: window
        title: "OmaConvert"
        // Quickshell windows default to visible: keep hidden until open().
        // Otherwise keepLoaded instantiation pops the window at every boot.
        visible: false
        color: root.menuTheme.background
        implicitWidth: 560
        implicitHeight: 720
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
            readonly property real availableWidth: width - 2 * root.spacing.panelPadding
            Keys.onEscapePressed: event => { if (service.busy) service.cancel(); else root.dismiss(); event.accepted = true }

            Shortcut {
                sequences: ["Ctrl+Return", "Ctrl+Enter"]
                enabled: root.opened && window.visible && !root.pickerBusy && (root.advanced ? root.canConvert : root.canRunSelected)
                context: Qt.WindowShortcut
                onActivated: root.advanced ? root.startConversion() : root.runRecipe(root.selectedRow)
            }

            Flickable {
                id: flick
                anchors.fill: parent
                anchors.margins: root.spacing.panelPadding
                anchors.rightMargin: root.spacing.panelPadding - Style.space(6)
                contentWidth: width
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar {
                    policy: flick.contentHeight > flick.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                    contentItem: Rectangle {
                        implicitWidth: Style.space(3)
                        radius: width / 2
                        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
                    }
                    background: Item {}
                }

                ColumnLayout {
                    id: content
                    x: Math.max(0, (flick.width - Style.space(6) - width) / 2)
                    width: Math.min(flick.width - Style.space(6), root.maxContentWidth)
                    spacing: Style.space(12)

                    // ── Header ────────────────────────────────────────────
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: Math.max(hero.implicitHeight, closeButton.implicitHeight)
                        Ui.PanelHero {
                            id: hero
                            anchors.left: parent.left
                            anchors.right: versionLabel.left
                            anchors.rightMargin: Style.space(12)
                            anchors.verticalCenter: parent.verticalCenter
                            title: "OmaConvert"
                            meta: service.busy ? "Converting" : (service.result ? "Ready to share" : "Videos and images made ready to share")
                            detail: service.metadata && !service.result ? (root.inputKind === "image" ? "Image" : "Video") : ""
                            foreground: root.fg
                            fontFamily: root.fontFamily
                            iconComponent: Component {
                                Text {
                                    text: "󰕧"
                                    color: Color.accent
                                    font.family: root.fonts.family
                                    font.pixelSize: root.fonts.display
                                }
                            }
                        }
                        Text {
                            id: versionLabel
                            anchors.right: closeButton.left
                            anchors.rightMargin: Style.space(8)
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: "v" + root.appVersion
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: root.fonts.caption
                            Accessible.name: "OmaConvert version " + root.appVersion
                        }
                        Ui.PanelActionButton {
                            id: closeButton
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            iconText: "󰅖"
                            tooltipText: "Close  ·  Esc"
                            foreground: root.fg
                            hoverColor: root.urgent
                            Accessible.name: "Close OmaConvert"
                            onClicked: root.dismiss()
                        }
                    }
                    Ui.PanelSeparator { Layout.fillWidth: true; foreground: root.fg }

                    // ── Source ────────────────────────────────────────────
                    Ui.PanelSectionHeader {
                        visible: !service.result
                        text: "SOURCE"
                        foreground: root.fg
                        fontFamily: root.fontFamily
                    }
                    Ui.BorderSurface {
                        id: choose
                        visible: !service.result
                        Layout.fillWidth: true
                        implicitHeight: Style.space(service.inputPath ? 52 : 84)
                        radius: Style.cornerRadius
                        enabled: !service.busy && !root.pickerBusy
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: chooseLabel.text
                        readonly property bool dragging: dropArea.containsDrag
                        readonly property bool hot: chooseMouse.containsMouse || dragging
                        color: dragging ? Style.selectedFillFor(root.fg, root.accent)
                             : chooseMouse.pressed ? Style.pressedFillFor(root.fg, root.accent)
                             : Style.controlFill(activeFocus, hot, root.fg, root.accent)
                        borderSpec: Border.controlSpec(dragging ? "selected" : (activeFocus ? "focus" : (hot ? "hover-cursor" : "normal")), root.fg, root.accent)
                        opacity: enabled || root.pickerBusy ? 1 : 0.5
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Keys.onReturnPressed: root.chooseVideo()
                        Keys.onEnterPressed: root.chooseVideo()
                        Keys.onSpacePressed: root.chooseVideo()

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(14)
                            anchors.rightMargin: Style.space(14)
                            spacing: Style.space(12)
                            Text {
                                text: root.pickerBusy ? "󰔟" : (service.inputPath ? (root.inputKind === "image" ? "󰋩" : "󰈫") : "󰇚")
                                color: service.inputPath ? root.accent : root.dim
                                font.family: root.fonts.family
                                font.pixelSize: root.fonts.iconLarge
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(2)
                                Text {
                                    id: chooseLabel
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: root.pickerBusy ? "Choosing file…"
                                        : choose.dragging ? "Drop to open"
                                        : (service.inputPath ? Model.name(service.inputPath) : "Choose a video or image")
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fonts.subtitle
                                    font.bold: service.inputPath !== ""
                                    elide: Text.ElideMiddle
                                }
                                Text {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: service.metadata !== null ? Model.mediaDescription(service.metadata)
                                        : (service.inputPath ? "Reading media…" : "Enter to browse  ·  or drop a file here")
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fonts.caption
                                    elide: Text.ElideRight
                                }
                            }
                            Text {
                                visible: service.inputPath !== "" && !root.pickerBusy
                                text: "Change"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fonts.caption
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
                        spacing: Style.space(4)
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
                    PreviewImage {
                        Layout.fillWidth: true
                        visible: service.metadata !== null && !service.result
                                 && (preview.sourceUrl !== "" || preview.sourceLoading)
                        title: "Preview"
                        imageSource: preview.sourceUrl
                        loading: preview.sourceLoading
                        meta: service.metadata ? Model.dimensionsText(service.metadata.width, service.metadata.height) : ""
                        foreground: root.fg
                        background: root.menuTheme.background
                        fontFamily: root.fontFamily
                        fontSize: root.fonts.body
                        radius: Style.cornerRadius
                    }
                    TrimBar {
                        id: trimBar
                        Layout.fillWidth: true
                        visible: root.trimShown && !service.result && !service.busy
                        duration: (service.metadata && service.metadata.duration) || 0
                        trackColor: Style.selectedFillFor(root.fg, root.accent)
                        fillColor: root.accent
                        knobColor: root.fg
                        knobBorderColor: root.menuTheme.background
                        textColor: root.fg
                        urgentColor: root.urgent
                        fontFamily: root.fontFamily
                        fontSize: root.fonts.body
                        controlHeight: root.spacing.controlHeight
                        onScrubRequested: (position) => {
                            if (service.inputPath) preview.requestSource(service.inputPath, position)
                        }
                    }

                    // ── Output: command line, recipes, all settings ───────
                    // Shown once the file is read: ready recipes for this
                    // file, a command line that understands "gif 30mb", and
                    // "+" for every field. Fields and the line stay in sync.
                    Ui.PanelSeparator { Layout.fillWidth: true; foreground: root.fg; visible: output.visible }
                    ColumnLayout {
                        id: output
                        Layout.fillWidth: true
                        visible: service.metadata !== null && !service.result && !service.busy
                        spacing: Style.space(10)
                        Ui.PanelSectionHeader {
                            text: root.advanced ? "ALL SETTINGS" : "WHAT TO MAKE"
                            foreground: root.fg
                            fontFamily: root.fontFamily
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(6)
                            Ui.TextField {
                                id: commandInput
                                Layout.fillWidth: true
                                foreground: root.fg
                                accent: root.accent
                                font.family: root.fontFamily
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
                            }
                            ActionButton {
                                id: plusButton
                                iconText: root.advanced ? "󰍴" : "󰐕"
                                tooltipText: root.advanced ? "Back to recipes" : "All settings"
                                selected: root.advanced
                                Accessible.name: root.advanced ? "Hide settings" : "Show all settings"
                                onClicked: root.toggleAdvanced()
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            visible: root.matched.chips.length > 0
                            spacing: Style.space(6)
                            Text {
                                textFormat: Text.PlainText
                                text: "Understood"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fonts.caption
                                height: Style.space(22)
                                verticalAlignment: Text.AlignVCenter
                            }
                            Repeater {
                                model: root.matched.chips
                                delegate: Ui.BorderSurface {
                                    id: chip
                                    required property var modelData
                                    implicitWidth: chipText.implicitWidth + Style.space(14)
                                    implicitHeight: Style.space(22)
                                    radius: Style.cornerRadius
                                    color: "transparent"
                                    borderSpec: Border.controlSpec(chip.modelData.ok ? "selected" : "normal", root.fg, root.accent)
                                    Text {
                                        id: chipText
                                        anchors.centerIn: parent
                                        textFormat: Text.PlainText
                                        text: chip.modelData.text
                                        color: chip.modelData.ok ? root.fg : root.dim
                                        font.family: root.fontFamily
                                        font.pixelSize: root.fonts.caption
                                        font.strikeout: !chip.modelData.ok
                                    }
                                }
                            }
                        }

                        // Recipes for this file, filtered by the command line.
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: !root.advanced
                            spacing: Style.space(4)
                            Repeater {
                                model: root.matched.rows
                                delegate: Ui.BorderSurface {
                                    id: recipeRow
                                    required property var modelData
                                    required property int index
                                    readonly property bool current: recipeRow.index === root.selectedRow
                                    readonly property bool blocked: recipeRow.modelData.problem !== ""
                                    Layout.fillWidth: true
                                    implicitHeight: recipeLine.implicitHeight + Style.space(16)
                                    radius: Style.cornerRadius
                                    color: recipeRow.current ? Style.selectedFillFor(root.fg, root.accent)
                                         : Style.controlFill(false, recipeMouse.containsMouse, root.fg, root.accent)
                                    borderSpec: Border.controlSpec(recipeRow.current ? "selected" : (recipeMouse.containsMouse ? "hover-cursor" : "normal"), root.fg, root.accent)
                                    Accessible.role: Accessible.Button
                                    Accessible.name: recipeRow.modelData.title + ". " + (recipeRow.modelData.problem || recipeRow.modelData.detail)
                                    RowLayout {
                                        id: recipeLine
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Style.space(12)
                                        anchors.rightMargin: Style.space(12)
                                        spacing: Style.space(12)
                                        Text {
                                            textFormat: Text.PlainText
                                            Layout.preferredWidth: Style.space(44)
                                            horizontalAlignment: Text.AlignHCenter
                                            text: recipeRow.modelData.fields.format === Model.SEQUENCE ? "SEQ" : recipeRow.modelData.fields.format
                                            color: recipeRow.current ? root.accent : root.dim
                                            font.family: root.fontFamily
                                            font.pixelSize: root.fonts.caption
                                            font.bold: true
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: Style.space(2)
                                            Text {
                                                textFormat: Text.PlainText
                                                Layout.fillWidth: true
                                                text: recipeRow.modelData.title
                                                color: root.fg
                                                opacity: recipeRow.blocked ? 0.5 : 1
                                                font.family: root.fontFamily
                                                font.pixelSize: root.fonts.body
                                                font.bold: true
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                Layout.fillWidth: true
                                                text: (recipeRow.modelData.last ? "Last used  ·  " : (recipeRow.modelData.custom ? "As typed  ·  " : ""))
                                                      + (recipeRow.modelData.problem || recipeRow.modelData.note || recipeRow.modelData.detail)
                                                color: recipeRow.blocked ? root.urgent : (recipeRow.modelData.note ? root.fg : root.dim)
                                                font.family: root.fontFamily
                                                font.pixelSize: root.fonts.caption
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                        Text {
                                            textFormat: Text.PlainText
                                            text: "↵"
                                            visible: recipeRow.current && !recipeRow.blocked
                                            color: root.accent
                                            font.family: root.fontFamily
                                            font.pixelSize: root.fonts.body
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
                                visible: text !== ""
                                text: root.matched.note
                                color: root.fg
                            }
                            Hint {
                                visible: root.outputFolder !== ""
                                text: "Saves to " + Model.folderLabel(root.outputFolder, root.homeDir) + "  ·  + to change"
                            }
                            Hint { text: "↑↓ choose  ·  Enter convert  ·  + all settings" }
                        }

                        // Every field, as before; edits rewrite the command line.
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.advanced
                            spacing: Style.space(10)
                            Repeater {
                                model: Model.formatGroups(root.inputKind, service.capabilities)
                                delegate: RowLayout {
                                    id: formatGroup
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: Style.space(10)
                                    FieldLabel { text: formatGroup.modelData.title }
                                    Ui.ButtonGroup {
                                        options: formatGroup.modelData.items
                                        value: formatGroup.modelData.items.indexOf(root.formatValue) >= 0 ? root.formatValue : ""
                                        foreground: root.fg
                                        accent: root.accent
                                        background: "transparent"
                                        fontFamily: root.fontFamily
                                        Accessible.name: formatGroup.modelData.title + " formats"
                                        onChanged: v => { root.formatValue = v; root.syncCommand() }
                                    }
                                }
                            }
                            Hint {
                                visible: text !== ""
                                text: root.unavailableFormats
                            }
                            RowLayout {
                                visible: root.formatValue !== Model.SEQUENCE
                                Layout.fillWidth: true
                                spacing: Style.space(10)
                                FieldLabel { text: "Mode" }
                                Ui.ButtonGroup {
                                    options: [{ value: "0", label: "Target size", icon: "󰘕" }, { value: "1", label: "Quick", icon: "󱐋" }]
                                    value: String(root.modeIndex)
                                    foreground: root.fg
                                    accent: root.accent
                                    background: "transparent"
                                    fontFamily: root.fontFamily
                                    Accessible.name: "Conversion mode"
                                    onChanged: v => { root.modeIndex = Number(v); root.syncCommand() }
                                }
                            }
                            RowLayout {
                                visible: root.sizeShown
                                Layout.fillWidth: true
                                spacing: Style.space(10)
                                FieldLabel { text: "Max size" }
                                Ui.TextField {
                                    id: sizeInput
                                    text: "50"
                                    Layout.preferredWidth: Style.space(88)
                                    foreground: root.fg
                                    accent: root.accent
                                    selectByMouse: true
                                    horizontalAlignment: TextInput.AlignRight
                                    Accessible.name: "Maximum file size"
                                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                                    onTextEdited: root.syncCommand()
                                }
                                Ui.ButtonGroup {
                                    options: ["MB", "KB"]
                                    value: root.unitText
                                    foreground: root.fg
                                    accent: root.accent
                                    background: "transparent"
                                    fontFamily: root.fontFamily
                                    Accessible.name: "Size unit"
                                    onChanged: v => { root.unitIndex = v === "KB" ? 1 : 0; root.syncCommand() }
                                }
                            }
                            Hint {
                                visible: root.sizeShown
                                text: Model.validSize(sizeInput.text) ? "1 MB = 1,000,000 bytes. Final file size is verified." : "Enter a size greater than zero, for example 50 or 0.5."
                                color: Model.validSize(sizeInput.text) ? root.dim : root.urgent
                            }
                            RowLayout {
                                visible: root.sizeShown && root.formatValue === "GIF" && root.inputKind !== "image"
                                Layout.fillWidth: true
                                spacing: Style.space(10)
                                FieldLabel { text: "Prefer" }
                                Ui.ButtonGroup {
                                    options: [{ value: "0", label: "Motion" }, { value: "1", label: "Balanced" }, { value: "2", label: "Detail" }]
                                    value: String(root.preferenceIndex)
                                    foreground: root.fg
                                    accent: root.accent
                                    background: "transparent"
                                    fontFamily: root.fontFamily
                                    Accessible.name: "Quality preference"
                                    onChanged: v => { root.preferenceIndex = Number(v); root.syncCommand() }
                                }
                            }
                            RowLayout {
                                visible: root.modeIndex === 1 && root.formatValue !== Model.SEQUENCE
                                Layout.fillWidth: true
                                spacing: Style.space(10)
                                FieldLabel { text: "Quality" }
                                Ui.ButtonGroup {
                                    options: [{ value: "0", label: "Small" }, { value: "1", label: "Balanced" }, { value: "2", label: "High" }]
                                    value: String(root.presetIndex)
                                    foreground: root.fg
                                    accent: root.accent
                                    background: "transparent"
                                    fontFamily: root.fontFamily
                                    Accessible.name: "Quality preset"
                                    onChanged: v => { root.presetIndex = Number(v); root.syncCommand() }
                                }
                            }
                            RowLayout {
                                visible: root.formatValue === Model.SEQUENCE
                                Layout.fillWidth: true
                                spacing: Style.space(10)
                                FieldLabel { text: "Frames" }
                                Ui.ButtonGroup {
                                    options: [{ value: "0", label: "Every frame" }, { value: "24", label: "24 fps" }, { value: "10", label: "10 fps" }, { value: "5", label: "5 fps" }, { value: "1", label: "1 fps" }]
                                    value: String(root.sequenceFps)
                                    foreground: root.fg
                                    accent: root.accent
                                    background: "transparent"
                                    fontFamily: root.fontFamily
                                    Accessible.name: "Frames per second to keep"
                                    onChanged: v => { root.sequenceFps = Number(v); root.syncCommand() }
                                }
                            }
                            RowLayout {
                                id: saveToRow
                                Layout.fillWidth: true
                                spacing: Style.space(10)
                                FieldLabel { text: "Save to" }
                                Text {
                                    id: saveToLabel
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: root.outputFolder ? Model.folderLabel(root.outputFolder, root.homeDir)
                                        : (service.inputPath ? "Next to source  ·  " + Model.folderLabel(Model.dirname(service.inputPath), root.homeDir) : "Next to source")
                                    color: root.outputFolder ? root.fg : root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fonts.body
                                    elide: Text.ElideLeft
                                    Accessible.name: "Output folder: " + text
                                }
                                ActionButton {
                                    iconText: "󰉋"
                                    text: folderPicker.running ? "Choosing…" : "Change"
                                    tooltipText: "Choose output folder"
                                    enabled: !root.pickerBusy
                                    onClicked: root.chooseFolder()
                                }
                                ActionButton {
                                    visible: root.outputFolder !== ""
                                    iconText: "󰅖"
                                    tooltipText: "Save next to the source again"
                                    Accessible.name: "Reset output folder"
                                    onClicked: root.setOutputFolder("")
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(10)
                                Item { Layout.preferredWidth: Style.space(104) }
                                ActionButton {
                                    bordered: false
                                    iconText: prefs.rememberFolder ? "󰄲" : "󰄱"
                                    text: "Remember this folder"
                                    selected: prefs.rememberFolder
                                    Accessible.name: "Remember output folder"
                                    onClicked: root.toggleRememberFolder()
                                }
                                Item { Layout.fillWidth: true }
                            }
                            Hint {
                                text: root.fieldsRecipe.detail
                            }
                            Hint {
                                visible: text !== ""
                                text: root.fieldsRecipe.problem || root.fieldsRecipe.note
                                color: root.fieldsRecipe.problem ? root.urgent : root.fg
                            }
                            ActionButton {
                                Layout.fillWidth: true
                                Layout.topMargin: Style.space(4)
                                implicitHeight: Style.space(36)
                                iconText: "󰑐"
                                text: "Convert  ·  Ctrl+Enter"
                                selected: true
                                enabled: root.canConvert
                                onClicked: root.startConversion()
                            }
                        }
                    }

                    // ── Progress ──────────────────────────────────────────
                    ColumnLayout {
                        visible: service.busy
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Ui.PanelSectionHeader { text: "CONVERTING"; foreground: root.fg; fontFamily: root.fontFamily }
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                text: service.phase
                                color: root.fg
                                font.family: root.fontFamily
                                font.pixelSize: root.fonts.body
                                wrapMode: Text.WordWrap
                            }
                            Text {
                                visible: !progressTrack.indeterminate
                                text: Math.round(service.progress * 100) + "%"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fonts.body
                                font.bold: true
                            }
                        }
                        Rectangle {
                            id: progressTrack
                            readonly property bool indeterminate: service.operation !== "convert" || service.phase.indexOf("Finding") === 0
                            Layout.fillWidth: true
                            implicitHeight: Math.max(4, Math.round(root.spacing.controlHeight * 0.14))
                            radius: height / 2
                            color: Style.selectedFillFor(root.fg, root.accent)
                            clip: true
                            Rectangle {
                                visible: !progressTrack.indeterminate
                                height: parent.height
                                radius: parent.radius
                                color: root.accent
                                width: parent.width * Math.max(0, Math.min(1, service.progress))
                                Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                            }
                            Rectangle {
                                id: sweep
                                visible: progressTrack.indeterminate
                                height: parent.height
                                radius: parent.radius
                                color: root.accent
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
                        Hint {
                            text: (service.candidate ? service.candidate.width + " px" + (service.candidate.fps ? "  ·  " + service.candidate.fps + " fps" : "") : "")
                                + (service.currentPass ? "  ·  Pass " + service.currentPass : "")
                                + (root.sizeShown ? "  ·  ≤ " + sizeInput.text + " " + root.unitText : "")
                        }
                        ActionButton {
                            iconText: "󰜺"
                            text: service.cancelling ? "Cancelling…" : "Cancel  ·  Esc"
                            enabled: !service.cancelling
                            onClicked: service.cancel()
                        }
                    }

                    // ── Result ────────────────────────────────────────────
                    Ui.PanelSectionHeader {
                        visible: service.result !== null && !service.busy
                        text: "RESULT"
                        foreground: root.fg
                        fontFamily: root.fontFamily
                    }
                    ResultView {
                        Layout.fillWidth: true
                        visible: service.result !== null && !service.busy
                        result: service.result || ({})
                        sourcePreview: preview.sourceUrl
                        resultPreview: preview.resultUrl
                        sourceLoading: preview.sourceLoading
                        resultLoading: preview.resultLoading
                        savings: (service.metadata && service.result) ? Model.savingsText(service.metadata.bytes, service.result.bytes) : ""
                        trimText: (service.result && service.result.trim_start !== undefined && service.metadata) ? Model.trimLabel(service.result.trim_start, service.result.trim_end, service.metadata.duration) : ""
                        sourceMeta: service.metadata ? Model.dimensionsText(service.metadata.width, service.metadata.height) : ""
                        resultMeta: service.result ? Model.dimensionsText(service.result.width, service.result.height) : ""
                        foreground: root.fg
                        background: root.menuTheme.background
                        accent: root.accent
                        fontFamily: root.fontFamily
                        fontSize: root.fonts.body
                        radius: Style.cornerRadius
                    }
                    Flow {
                        Layout.fillWidth: true
                        visible: service.result !== null && !service.busy
                        spacing: Style.space(6)
                        ActionButton { iconText: "󰈔"; text: service.result && service.result.kind === "sequence" ? "Open frames" : "Open file"; onClicked: Qt.openUrlExternally(Model.fileUri(service.result.path)) }
                        ActionButton { iconText: "󰉋"; text: "Open folder"; onClicked: Qt.openUrlExternally(Model.fileUri(service.result.path.substring(0, service.result.path.lastIndexOf("/")) || "/")) }
                        ActionButton { iconText: "󰆏"; text: service.result && service.result.kind === "sequence" ? "Copy folder" : "Copy file"; onClicked: root.copy(Model.fileUri(service.result.path) + "\r\n", true) }
                        ActionButton { iconText: "󰅍"; text: "Copy path"; onClicked: root.copy(service.result.path, false) }
                    }
                    ActionButton {
                        visible: service.result !== null && !service.busy
                        Layout.fillWidth: true
                        implicitHeight: Style.space(36)
                        iconText: "󰐕"
                        text: "Convert another"
                        selected: true
                        onClicked: { service.result = null; service.metadata = null; service.inputPath = ""; service.phase = ""; root.clipboardStatus = ""; preview.clearAll(); choose.forceActiveFocus() }
                    }

                    // ── Status ────────────────────────────────────────────
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
                        Layout.maximumHeight: Style.space(120)
                        visible: detailsButton.checked && service.details !== ""
                        text: service.details
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.WrapAnywhere
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fonts.caption
                        background: Ui.BorderSurface {
                            color: Style.normalFillFor(root.fg, root.accent)
                            borderSpec: Border.controlSpec("normal", root.fg, root.accent)
                            radius: Style.cornerRadius
                        }
                    }
                }
            }
        }
    }
}
