pragma ComponentBehavior: Bound
import QtQuick
import QtCore
import Quickshell
import "Model.js" as Model

// What the window is doing, without any of its look: the request being
// built (recipes, the command line and every field, kept in sync), which
// screen is showing, pinned recipes, the batch totals, and starting a
// conversion. The window binds its controls to these properties and calls
// these functions; the persisted choices live in `prefs`.
Item {
    id: root
    required property ConvertService service
    // From the window: a file or folder picker is open.
    property bool pickerBusy: false
    // From the trim bar: the kept part of the video.
    property real trimStart: 0
    property real trimEnd: 0
    property bool trimValid: true

    readonly property string configRoot: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    property url settingsLocation: Model.fileUri(root.configRoot + "/omaconvert/preferences.ini")
    readonly property alias prefs: settings

    // The typed command line ("gif 30mb") and the size field.
    property string commandText: ""
    property string sizeText: "50"
    // Form state (persisted through the Settings aliases below).
    property string formatValue: ""
    property int modeIndex: 0
    property int unitIndex: 0
    property int preferenceIndex: 1
    property int presetIndex: 1
    property int sequenceFps: 0
    // Recipe list vs. every field (settings); which recipe Enter runs.
    property bool advanced: false
    property int selectedRow: 0
    // Destination folder for the next conversion; "" saves next to the source.
    // Only persisted (prefs.savedFolder) when the user asked to remember it.
    property string outputFolder: ""
    // The running job, for the converting screen.
    property real jobLimitBytes: 0
    property string jobCommand: ""
    signal conversionStarted()

    readonly property string inputKind: root.service.metadata && root.service.metadata.kind === "image" ? "image" : "video"
    readonly property var formatOptions: Model.commandFormats(root.inputKind, root.service.capabilities)
    readonly property string unavailableFormats: Model.unavailableText(root.inputKind, root.service.capabilities)
    readonly property string unitText: ["MB", "KB"][root.unitIndex] || "MB"
    onFormatOptionsChanged: if (root.formatOptions.indexOf(root.formatValue) < 0) Qt.callLater(root.resetRecipes)
    Component.onCompleted: {
        if (settings.rememberFolder) root.outputFolder = settings.savedFolder
    }
    readonly property bool trimShown: !root.service.isBatch && root.service.metadata !== null && root.service.metadata.kind !== "image" && (root.service.metadata.duration || 0) > 0
    readonly property bool sizeShown: root.modeIndex === 0 && root.formatValue !== Model.SEQUENCE
    // Seconds that will be converted: the trimmed part of a video.
    readonly property real convertSeconds: root.trimShown ? Math.max(0, root.trimEnd - root.trimStart) : ((root.service.metadata && root.service.metadata.duration) || 0)
    readonly property string lastCommand: root.inputKind === "image" ? settings.lastImageCommand : settings.lastVideoCommand
    // Without the trimmed length: dragging a trim handle must not rebuild
    // every recipe row. Rows work out their length-dependent texts.
    readonly property var matched: root.service.metadata
        ? Model.matchRecipes(root.commandText, root.inputKind, root.service.metadata, root.service.capabilities, root.lastCommand, 0, root.pinned)
        : ({ rows: [], chips: [], note: "" })
    readonly property var fieldsRecipe: Model.recipe(root.currentFields(), root.inputKind, root.service.metadata, root.service.capabilities, root.convertSeconds)
    readonly property bool readyToConvert: !root.service.busy && !root.pickerBusy && root.service.metadata !== null && root.service.dependenciesReady && (!root.trimShown || root.trimValid)
    // The same checks as a recipe row (sound, size, a known duration for a
    // size target), so the panel never starts what the list would block.
    readonly property bool canConvert: root.readyToConvert && root.fieldsRecipe.problem === "" && root.formatOptions.indexOf(root.formatValue) >= 0
    // Format that Enter would run: the fields with settings open, else the highlighted recipe.
    readonly property string activeFormat: root.advanced ? root.formatValue
        : (root.selectedRow < root.matched.rows.length ? root.matched.rows[root.selectedRow].fields.format : "")
    // What Enter would make: the fields with settings open, else the highlighted recipe.
    readonly property var activeFields: root.advanced ? root.currentFields()
        : (root.selectedRow < root.matched.rows.length ? root.matched.rows[root.selectedRow].fields : null)
    readonly property real activeLimit: root.activeFields && root.activeFields.mode === "target" && root.activeFields.format !== Model.SEQUENCE
        ? Model.limitBytes(root.activeFields.size, root.activeFields.unit) : 0
    readonly property bool idleWithFile: root.service.metadata !== null && !root.service.result && !root.service.busy
    readonly property string screen: root.service.result && !root.service.busy ? "result"
        : (root.service.busy && (root.service.operation === "convert" || root.service.operation === "batch") ? "converting"
        : (root.idleWithFile ? (root.advanced ? "settings" : "recipes") : "empty"))
    readonly property bool canRunSelected: root.readyToConvert && root.selectedRow < root.matched.rows.length && root.matched.rows[root.selectedRow].problem === ""

    // Fields <-> the command line. A recipe, the typed text and the settings
    // panel all end up as these properties; startConversion() reads them.
    function currentFields() {
        return {
            format: root.formatValue,
            mode: root.modeIndex === 1 || root.formatValue === Model.SEQUENCE ? "quick" : "target",
            size: root.sizeText, unit: root.unitText,
            preference: Model.PREFERENCES[root.preferenceIndex] || "balanced",
            preset: Model.PRESETS[root.presetIndex] || "balanced",
            sequenceFps: root.sequenceFps
        }
    }
    function applyFields(fields) {
        if (!fields) return
        if (fields.format) root.formatValue = fields.format
        if (fields.mode) root.modeIndex = fields.mode === "quick" ? 1 : 0
        if (fields.size) root.sizeText = fields.size
        if (fields.unit) root.unitIndex = fields.unit === "KB" ? 1 : 0
        if (fields.preference) root.preferenceIndex = Math.max(0, Model.PREFERENCES.indexOf(fields.preference))
        if (fields.preset) root.presetIndex = Math.max(0, Model.PRESETS.indexOf(fields.preset))
        if (fields.sequenceFps !== undefined) root.sequenceFps = Number(fields.sequenceFps) || 0
    }
    // A settings edit rewrites the command line.
    function syncCommand() {
        if (root.advanced) root.commandText = Model.commandText(root.currentFields(), root.inputKind)
    }
    // Typing filters the recipes; with settings open it also fills the fields.
    function editCommand(text) {
        root.commandText = text
        root.selectedRow = 0
        if (root.advanced) root.applyFields(Model.parseCommand(text, root.inputKind, root.formatOptions).fields)
    }
    function moveSelection(step) {
        if (!root.advanced) root.selectedRow = Math.max(0, Math.min(root.matched.rows.length - 1, root.selectedRow + step))
    }
    // Enter: the fields with settings open, else the highlighted recipe.
    function runActive() {
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
        root.commandText = ""
        var first = Model.recipes(root.inputKind, root.service.metadata, root.service.capabilities, root.lastCommand, root.convertSeconds, root.pinned)[0]
        if (first) root.applyFields(first.fields)
        else if (root.formatOptions.indexOf(root.formatValue) < 0) root.formatValue = root.formatOptions[0] || ""
    }
    function setOutputFolder(path) {
        root.outputFolder = path || ""
        if (settings.rememberFolder) settings.savedFolder = root.outputFolder
    }
    function toggleRememberFolder() {
        settings.rememberFolder = !settings.rememberFolder
        settings.savedFolder = settings.rememberFolder ? root.outputFolder : ""
    }
    function startConversion() {
        if (!root.canConvert) return
        var command = Model.commandText(root.currentFields(), root.inputKind)
        root.jobCommand = command
        root.jobLimitBytes = root.sizeShown ? Model.limitBytes(root.sizeText, root.unitText) : 0
        if (root.inputKind === "image") settings.lastImageCommand = command
        else settings.lastVideoCommand = command
        settings.sync()
        root.conversionStarted()
        var useTrim = root.trimShown
        var sequence = root.formatValue === Model.SEQUENCE
        if (root.service.isBatch) {
            root.service.convertBatch(sequence ? "png" : root.formatValue.toLowerCase(), root.sizeShown ? "target" : "quick",
                                      root.sizeText, root.unitText, Model.PRESETS[root.presetIndex] || "balanced",
                                      Model.PREFERENCES[root.preferenceIndex] || "balanced", root.outputFolder,
                                      sequence ? root.sequenceFps : null)
            return
        }
        root.service.convert(sequence ? "png" : root.formatValue.toLowerCase(), root.sizeShown ? "target" : "quick",
                             root.sizeText, root.unitText, Model.PRESETS[root.presetIndex] || "balanced",
                             Model.PREFERENCES[root.preferenceIndex] || "balanced",
                             useTrim ? root.trimStart : 0, useTrim ? root.trimEnd : 0, root.outputFolder,
                             sequence ? root.sequenceFps : null)
    }
    // Back to an empty window: no file, no result, no batch.
    function clear() {
        root.service.replaceBatch([])
        root.service.batchKind = ""
        root.service.result = null
        root.service.metadata = null
        root.service.inputPath = ""
        root.service.phase = ""
    }

    // ── Pinned recipes: per kind, shown first ───────────────────────────
    readonly property var pinned: Model.parsePinned(root.inputKind === "image" ? settings.pinnedImage : settings.pinnedVideo)
    // The recipe Enter would run right now, as command words.
    readonly property string activeCommand: root.advanced ? Model.commandText(root.currentFields(), root.inputKind)
        : (root.selectedRow < root.matched.rows.length ? root.matched.rows[root.selectedRow].command : "")
    readonly property bool activePinned: root.activeCommand !== "" && root.pinned.indexOf(root.activeCommand) >= 0
    function togglePin() {
        if (!root.activeCommand) return
        var next = JSON.stringify(Model.togglePinned(root.pinned, root.activeCommand))
        if (root.inputKind === "image") settings.pinnedImage = next
        else settings.pinnedVideo = next
    }

    // ── Batch totals ─────────────────────────────────────────────────────
    readonly property var batchReady: root.service.batch.filter(item => item.ok && item.status !== "skipped")
    readonly property real batchBytes: root.batchReady.reduce((sum, item) => sum + (item.bytes || 0), 0)
    readonly property int batchFinished: root.service.batch.filter(item => item.status === "done" || item.status === "failed" && item.ok).length
    readonly property real batchProgress: root.batchReady.length
        ? Math.min(1, (root.batchFinished + root.batchWorking.reduce((sum, item) => sum + (item.progress || 0), 0)) / root.batchReady.length) : 0
    // Files being converted right now: several for still images.
    readonly property var batchWorking: root.service.batch.filter(item => item.status === "working")
    function batchTitle() {
        var n = root.batchReady.length
        var word = root.service.batchKind === "image" ? (n === 1 ? "image" : "images") : (n === 1 ? "video" : "videos")
        return n + " " + word + "  ·  " + Model.compactSize(root.batchBytes)
    }
    function batchNote() {
        var skipped = root.service.batch.filter(item => item.status === "skipped").length
        var unreadable = root.service.batch.filter(item => item.ok === false).length
        var parts = []
        if (skipped) parts.push(skipped + " skipped (other kind)")
        if (unreadable) parts.push(unreadable + " unreadable")
        return parts.join("  ·  ")
    }
    function batchFolder() {
        var paths = root.service.result && root.service.result.paths ? root.service.result.paths : []
        return paths.length ? Model.dirname(paths[0]) : ""
    }

    Settings {
        id: settings
        location: root.settingsLocation
        // Last conversion per input kind, as command words ("gif 50mb");
        // offered first the next time a file of that kind is opened.
        property string lastVideoCommand: ""
        property string lastImageCommand: ""
        // Pinned recipe commands as JSON arrays, e.g. ["jpg 150kb"].
        property string pinnedVideo: "[]"
        property string pinnedImage: "[]"
        property alias modeIndex: root.modeIndex
        property alias sizeText: root.sizeText
        property alias unitIndex: root.unitIndex
        property alias preferenceIndex: root.preferenceIndex
        property alias presetIndex: root.presetIndex
        property bool rememberFolder: false
        property bool offerRecordings: true
        property string savedFolder: ""
    }
}
