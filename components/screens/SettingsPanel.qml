pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../../services"
import "../../services/Model.js" as Model
import "../ui"
import ".."

// Every field of the request; edits rewrite the command line. Ends with
// what Enter will make and the button that makes it.
Rectangle {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    property string homeDir: ""
    property bool pickerBusy: false
    property bool choosingFolder: false
    signal chooseFolderRequested()
    Layout.fillWidth: true
    visible: root.session.advanced
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
                    model: Model.formatGroups(root.session.inputKind, root.service.capabilities)
                    delegate: Segments {
                        id: formatGroup
                        required property var modelData
                        options: formatGroup.modelData.items.map(item => ({ value: item, label: item === Model.SEQUENCE ? "SEQ" : item.toUpperCase() }))
                        value: formatGroup.modelData.items.indexOf(root.session.formatValue) >= 0 ? root.session.formatValue : ""
                        theme: root.theme
                        Accessible.name: formatGroup.modelData.title + " formats"
                        onChanged: v => { root.session.formatValue = v; root.session.syncCommand() }
                    }
                }
            }
            Hint {
                theme: root.theme
                text: root.session.unavailableFormats !== "" ? root.session.unavailableFormats
                    : (root.session.inputKind === "image" ? "image formats" : "video formats  ·  stills  ·  SEQ = every frame as PNG")
                color: root.theme.faint
                font.pixelSize: root.theme.px(0.833)
            }
        }
        FieldRow {
            theme: root.theme
            label: "MODE"
            enabled: root.session.formatValue !== Model.SEQUENCE
            Segments {
                options: [{ value: "0", label: "target size" }, { value: "1", label: "quick" }]
                value: String(root.session.modeIndex)
                theme: root.theme
                Accessible.name: "Conversion mode"
                onChanged: v => { root.session.modeIndex = Number(v); root.session.syncCommand() }
            }
        }
        FieldRow {
            theme: root.theme
            label: "MAX SIZE"
            enabled: root.session.sizeShown
            RowLayout {
                spacing: 8
                LineEdit {
                    id: sizeInput
                    theme: root.theme
                    text: root.session.sizeText
                    Layout.preferredWidth: root.theme.px(6.5)
                    bold: true
                    alignRight: true
                    maximumLength: 9
                    accepts: ch => /^[0-9.,]$/.test(ch)
                    Accessible.name: "Maximum file size"
                    onEdited: value => { root.session.sizeText = value; root.session.syncCommand() }
                }
                Segments {
                    options: ["MB", "KB"]
                    value: root.session.unitText
                    theme: root.theme
                    Accessible.name: "Size unit"
                    onChanged: v => { root.session.unitIndex = v === "KB" ? 1 : 0; root.session.syncCommand() }
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
                        readonly property bool on: root.session.sizeText === String(presetChip.modelData.size) && root.session.unitText === presetChip.modelData.unit
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
                                root.session.sizeText = String(presetChip.modelData.size)
                                root.session.unitIndex = presetChip.modelData.unit === "KB" ? 1 : 0
                                root.session.syncCommand()
                            }
                        }
                    }
                }
            }
            Hint {
                theme: root.theme
                visible: !Model.validSize(root.session.sizeText)
                text: "Enter a size greater than zero, for example 50 or 0.5."
                color: root.theme.urgent
                font.pixelSize: root.theme.px(0.833)
            }
        }
        FieldRow {
            theme: root.theme
            label: "PREFER"
            enabled: root.session.sizeShown && root.session.formatValue === "GIF" && root.session.inputKind !== "image"
            Segments {
                options: [{ value: "0", label: "motion" }, { value: "1", label: "balanced" }, { value: "2", label: "detail" }]
                value: String(root.session.preferenceIndex)
                theme: root.theme
                Accessible.name: "Quality preference"
                onChanged: v => { root.session.preferenceIndex = Number(v); root.session.syncCommand() }
            }
            Hint {
                theme: root.theme
                text: ["GIF only  ·  keep smooth motion, drop resolution first",
                       "GIF only  ·  trade resolution and frame rate evenly",
                       "GIF only  ·  keep a sharp picture, drop frames first"][root.session.preferenceIndex] || ""
                color: root.theme.faint
                font.pixelSize: root.theme.px(0.833)
            }
        }
        FieldRow {
            theme: root.theme
            label: "QUALITY"
            visible: root.session.formatValue !== Model.SEQUENCE
            enabled: root.session.modeIndex === 1
            Segments {
                options: [{ value: "0", label: "small" }, { value: "1", label: "balanced" }, { value: "2", label: "high" }]
                value: String(root.session.presetIndex)
                theme: root.theme
                Accessible.name: "Quality preset"
                onChanged: v => { root.session.presetIndex = Number(v); root.session.syncCommand() }
            }
        }
        FieldRow {
            theme: root.theme
            label: "FRAMES"
            visible: root.session.formatValue === Model.SEQUENCE
            Segments {
                options: [{ value: "0", label: "every" }, { value: "24", label: "24 fps" }, { value: "10", label: "10 fps" }, { value: "5", label: "5 fps" }, { value: "1", label: "1 fps" }]
                value: String(root.session.sequenceFps)
                theme: root.theme
                Accessible.name: "Frames per second to keep"
                onChanged: v => { root.session.sequenceFps = Number(v); root.session.syncCommand() }
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
                    text: root.session.outputFolder ? Model.folderLabel(root.session.outputFolder, root.homeDir)
                        : (root.service.inputPath ? "next to source  ·  " + Model.folderLabel(Model.dirname(root.service.inputPath), root.homeDir) : "next to source")
                    color: root.session.outputFolder ? root.theme.fg : root.theme.dim
                    font.bold: root.session.outputFolder !== ""
                    elide: Text.ElideLeft
                    Accessible.name: "Output folder: " + text
                }
                TextButton {
                    theme: root.theme
                    label: root.choosingFolder ? "choosing…" : "change"
                    enabled: !root.pickerBusy
                    onClicked: root.chooseFolderRequested()
                }
                TextButton {
                    theme: root.theme
                    visible: root.session.outputFolder !== ""
                    label: "×"
                    Accessible.name: "Save next to the source again"
                    onClicked: root.session.setOutputFolder("")
                }
            }
            Row {
                spacing: 8
                activeFocusOnTab: true
                Accessible.role: Accessible.CheckBox
                Accessible.name: "Remember this folder"
                Keys.onSpacePressed: root.session.toggleRememberFolder()
                Rectangle {
                    width: 11
                    height: 11
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.session.prefs.rememberFolder ? root.theme.sage : "transparent"
                    border.width: 1
                    border.color: parent.activeFocus ? root.theme.focus : (root.session.prefs.rememberFolder ? root.theme.sage : root.theme.alpha(root.theme.fg, 0.4))
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
                        onClicked: root.session.toggleRememberFolder()
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
                        text: Model.outputName(root.service.inputPath, root.session.currentFields())
                        font.bold: true
                        elide: Text.ElideMiddle
                    }
                    MonoText {
                        theme: root.theme
                        size: 0.833
                        Layout.fillWidth: true
                        text: root.session.fieldsRecipe.problem || root.session.fieldsRecipe.note || root.session.fieldsRecipe.detail
                        color: root.session.fieldsRecipe.problem ? root.theme.urgent : root.theme.dim
                        wrapMode: Text.WordWrap
                    }
                }
                TextButton {
                    theme: root.theme
                    key: "★"
                    label: root.session.activePinned ? "unpin" : "pin"
                    Accessible.name: root.session.activePinned ? "Unpin this recipe" : "Pin this recipe to the top of the list"
                    onClicked: root.session.togglePin()
                }
                Rectangle {
                    id: convertButton
                    implicitWidth: convertRow.implicitWidth + 28
                    implicitHeight: convertRow.implicitHeight + 18
                    color: root.session.canConvert ? (convertMouse.pressed ? Qt.darker(root.theme.focus, 1.15) : root.theme.focus) : root.theme.alpha(root.theme.fg, 0.12)
                    border.width: convertButton.activeFocus ? 2 : 0
                    border.color: root.theme.fg
                    activeFocusOnTab: root.session.canConvert
                    Accessible.role: Accessible.Button
                    Accessible.name: "Convert"
                    Keys.onReturnPressed: root.session.startConversion()
                    Keys.onEnterPressed: root.session.startConversion()
                    Keys.onSpacePressed: root.session.startConversion()
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
                                color: root.session.canConvert ? root.theme.bg : root.theme.faint
                                font.bold: true
                            }
                        }
                    }
                    MouseArea {
                        id: convertMouse
                        anchors.fill: parent
                        cursorShape: root.session.canConvert ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root.session.startConversion()
                    }
                }
            }
        }
    }
}
