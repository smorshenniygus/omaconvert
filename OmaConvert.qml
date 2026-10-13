pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "services"
import "services/Model.js" as Model
import "components"
import "components/ui"
import "components/screens"
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
    property string clipboardText: ""
    property string clipboardStatus: ""
    readonly property bool pickerBusy: filePicker.running || folderPicker.running
    readonly property string homeDir: Quickshell.env("HOME") || ""
    readonly property ConvertService convertService: service
    // What the window is doing: the request, the screen, starting a job.
    readonly property Session session: Session {
        service: root.convertService
        pickerBusy: root.pickerBusy
        trimStart: trimBar.startTime
        trimEnd: trimBar.endTime
        trimValid: trimBar.valid
        onConversionStarted: root.clipboardStatus = ""
    }
    readonly property PreviewService previewService: preview
    readonly property var panelWindow: window
    readonly property var panelCard: card
    readonly property var trimControl: trimBar
    readonly property var commandField: commandLine.field
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
            preview.requestSource(service.inputPath, root.session.trimShown ? trimBar.playhead : 0, false, service.metadata)
            if (service.result && service.result.path) preview.requestResult(service.result.first_frame || service.result.path)
        }
        service.loadStatus()
        Qt.callLater(() => choose.forceActiveFocus())
    }
    function chooseVideo() {
        if (!service.busy && !filePicker.running) filePicker.running = true
    }
    function chooseFolder() {
        if (!service.busy && !root.pickerBusy) folderPicker.running = true
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
    function convertAnother() {
        root.session.clear()
        root.clipboardStatus = ""
        preview.clearAll()
        choose.forceActiveFocus()
    }
    // What the result screen offers: its rows, their keys and the key bar
    // hints all come from this list. The first action is the primary one.
    readonly property var resultActions: {
        var result = service.result
        if (!result) return []
        if (service.isBatch) return [
            { key: "⏎", hint: "folder", glyph: "󰉋", label: "Open the folder", run: () => Qt.openUrlExternally(Model.fileUri(root.session.batchFolder())) },
            { key: "c", hint: "copy all", glyph: "󰆏", label: "Copy all files to clipboard", run: () => root.copy(result.paths.map(p => Model.fileUri(p)).join("\r\n") + "\r\n", true) },
            { key: "p", hint: "paths", glyph: "󰅍", label: "Copy all paths", run: () => root.copy(result.paths.join("\n"), false) },
            { key: "n", hint: "more", glyph: "󰐕", label: "Convert more", run: () => root.convertAnother() }
        ]
        var sequence = result.kind === "sequence"
        return [
            { key: "⏎", hint: "open", glyph: "󰈔", label: sequence ? "Open frames" : "Open file", run: () => Qt.openUrlExternally(Model.fileUri(result.path)) },
            { key: "o", hint: "folder", glyph: "󰉋", label: "Show in folder", run: () => root.openResultFolder() },
            { key: "c", hint: "copy", glyph: "󰆏", label: sequence ? "Copy folder to clipboard" : "Copy file to clipboard", run: () => root.copy(Model.fileUri(result.path) + "\r\n", true) },
            { key: "p", hint: "path", glyph: "󰅍", label: "Copy path", run: () => root.copy(result.path, false) },
            { key: "n", hint: "another", glyph: "󰐕", label: "Convert another", run: () => root.convertAnother() }
        ]
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
                    root.session.resetRecipes()
                    if (root.opened) commandLine.field.forceActiveFocus()
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
        function onPasteFailed(message) { root.pasteNote = "Could not paste. " + message }
        function onPasted(result) {
            if (result.kind === "file") service.selectFiles(result.paths && result.paths.length ? result.paths : [result.path])
            else if (result.kind === "text" && root.session.idleWithFile) {
                commandLine.field.insert(commandLine.field.cursorPosition, result.text)
                commandLine.field.forceActiveFocus()
            } else root.pasteNote = result.kind === "text"
                ? "The clipboard holds text, not a file or an image."
                : result.reason === "too-large" ? "The clipboard is too large to paste."
                : "Nothing to paste: copy an image, a screenshot or a file first."
        }
    }
    // A finished Omarchy screen recording over 10 MB gets a notification
    // that opens it here (the backend checks the file and its size).
    RecordingWatch {
        watching: root.session.prefs.offerRecordings
        onEnded: file => Quickshell.execDetached(["python3", service.executable, "--offer-recording", file])
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
                if (path) root.session.setOutputFolder(path)
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
                else if (root.session.screen === "settings") root.session.toggleAdvanced()
                else root.dismiss()
                event.accepted = true
            }

            Shortcut {
                sequences: ["Ctrl+Return", "Ctrl+Enter"]
                enabled: root.opened && window.visible && !root.pickerBusy && (root.session.advanced ? root.session.canConvert : root.session.canRunSelected)
                context: Qt.WindowShortcut
                onActivated: root.session.advanced ? root.session.startConversion() : root.session.runRecipe(root.session.selectedRow)
            }
            Shortcut {
                sequences: [StandardKey.Paste]
                enabled: root.opened && window.visible && !service.busy && root.session.screen !== "settings"
                context: Qt.WindowShortcut
                onActivated: root.pasteFromClipboard()
            }
            Shortcut {
                sequence: "Ctrl+,"
                enabled: root.session.idleWithFile
                context: Qt.WindowShortcut
                onActivated: root.session.toggleAdvanced()
            }
            // Alt+1… runs a recipe: plain digits belong to the command line.
            Repeater {
                model: 9
                delegate: Item {
                    id: recipeKey
                    required property int index
                    Shortcut {
                        sequence: "Alt+" + (recipeKey.index + 1)
                        enabled: root.session.screen === "recipes" && recipeKey.index < root.session.matched.rows.length
                        context: Qt.WindowShortcut
                        onActivated: root.session.runRecipe(recipeKey.index)
                    }
                }
            }
            // Result keys: the same list as the action rows and the key bar.
            Repeater {
                model: root.resultActions
                delegate: Item {
                    id: resultKey
                    required property var modelData
                    Shortcut {
                        sequences: resultKey.modelData.key === "⏎" ? ["Return", "Enter"] : [resultKey.modelData.key.toUpperCase()]
                        enabled: root.session.screen === "result"
                        context: Qt.WindowShortcut
                        onActivated: resultKey.modelData.run()
                    }
                }
            }
            Shortcut { sequence: "Ctrl+D"; enabled: root.session.screen === "recipes" || root.session.screen === "settings"; context: Qt.WindowShortcut; onActivated: root.session.togglePin() }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                TitleBar {
                    theme: root.theme
                    session: root.session
                    service: root.convertService
                    appVersion: root.appVersion
                    onCloseRequested: root.dismiss()
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

                        SourceHeader {
                            id: choose
                            theme: root.theme
                            session: root.session
                            service: root.convertService
                            pickerBusy: root.pickerBusy
                            onChooseRequested: root.chooseVideo()
                        }
                        BatchList {
                            theme: root.theme
                            session: root.session
                            service: root.convertService
                            onChooseRequested: root.chooseVideo()
                        }
                        IntegrationSwitches {
                            theme: root.theme
                            session: root.session
                            service: root.convertService
                        }

                        // ── Preview + trim ────────────────────────────────
                        PreviewImage {
                            id: sourcePreview
                            Layout.fillWidth: true
                            visible: root.session.idleWithFile && !service.isBatch && (preview.sourceUrl !== "" || preview.sourceLoading)
                            title: "Preview"
                            showHeader: false
                            boxHeight: root.session.advanced ? 150 : Math.min(292, Math.round(width * 0.5625))
                            imageSource: preview.sourceUrl
                            loading: preview.sourceLoading
                            overlayText: root.session.trimShown ? Model.timeText(trimBar.playhead) : ""
                            overlayDot: root.theme.urgent
                            badgeText: service.metadata ? (root.session.inputKind === "image" ? Model.dimensionsText(service.metadata.width, service.metadata.height)
                                : Math.min(service.metadata.width, service.metadata.height) + "p" + (Model.isHdr(service.metadata) ? "  ·  HDR" : "")) : ""
                            theme: root.theme
                            Behavior on boxHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                        }
                        TrimBar {
                            id: trimBar
                            Layout.fillWidth: true
                            visible: root.session.trimShown && root.session.idleWithFile
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
                            visible: root.session.idleWithFile && !service.isBatch && (service.metadata.bytes || 0) > 0
                            fromBytes: (service.metadata && service.metadata.bytes) || 0
                            limitBytes: root.session.activeLimit
                            theme: root.theme
                        }

                        // ── Command line, recipes, all settings ──────────
                        // Recipes for this file, a line that understands
                        // "gif 30mb", and every field behind the settings
                        // button. Fields and the line stay in sync.
                        ColumnLayout {
                            id: output
                            Layout.fillWidth: true
                            visible: root.session.idleWithFile
                            spacing: 8
                            CommandLine {
                                id: commandLine
                                theme: root.theme
                                session: root.session
                                onPasteRequested: root.pasteFromClipboard()
                            }
                            RecipeList {
                                theme: root.theme
                                session: root.session
                                service: root.convertService
                                homeDir: root.homeDir
                            }
                            SettingsPanel {
                                theme: root.theme
                                session: root.session
                                service: root.convertService
                                homeDir: root.homeDir
                                pickerBusy: root.pickerBusy
                                choosingFolder: folderPicker.running
                                onChooseFolderRequested: root.chooseFolder()
                            }
                        }

                        ConvertingView {
                            theme: root.theme
                            session: root.session
                            service: root.convertService
                            preview: root.previewService
                        }
                        // Reading a file: the phase on its own.
                        Hint {
                            theme: root.theme
                            visible: service.busy && root.session.screen !== "converting"
                            text: service.phase
                        }

                        // ── Result ────────────────────────────────────────
                        ResultView {
                            Layout.fillWidth: true
                            visible: root.session.screen === "result" && !service.isBatch
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
                            limitBytes: root.session.jobLimitBytes
                            theme: root.theme
                        }
                        BatchSummary {
                            theme: root.theme
                            session: root.session
                            service: root.convertService
                        }
                        ResultActions {
                            visible: root.session.screen === "result"
                            theme: root.theme
                            actions: root.resultActions
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
                        Hint { theme: root.theme; text: service.notice; visible: text !== "" && !service.busy && (text.indexOf("gifsicle") < 0 || (root.session.inputKind !== "image" && root.session.activeFormat === "GIF")) }
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
                        // Plain text, not a text area: an editable or selectable Qt
                        // text item would watch the clipboard (see LineEdit).
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: Math.min(120, detailsText.implicitHeight + 16)
                            visible: detailsButton.checked && service.details !== ""
                            color: root.theme.surface
                            border.width: 1
                            border.color: root.theme.line
                            clip: true
                            Flickable {
                                id: detailsFlick
                                anchors.fill: parent
                                anchors.margins: 8
                                contentHeight: detailsText.implicitHeight
                                interactive: contentHeight > height
                                boundsBehavior: Flickable.StopAtBounds
                                MonoText {
                                    id: detailsText
                                    theme: root.theme
                                    width: detailsFlick.width
                                    text: service.details
                                    color: root.theme.dim
                                    font.pixelSize: root.theme.caption
                                    wrapMode: Text.WrapAnywhere
                                }
                            }
                            TextButton {
                                theme: root.theme
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 6
                                label: "copy"
                                Accessible.name: "Copy the details"
                                onClicked: root.copy(service.details, false)
                            }
                        }
                    }
                }

                KeyBar {
                    theme: root.theme
                    session: root.session
                    resultKeys: root.resultActions.map(action => [action.key, action.hint])
                }
            }
        }
    }
}
