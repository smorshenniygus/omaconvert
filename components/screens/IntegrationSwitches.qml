pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../../services"
import "../../services/Model.js" as Model
import "../ui"

// Omarchy integration, offered before a file is chosen. Each switch is
// opt-in and undone the same way.
ColumnLayout {
    id: root
    required property Theme theme
    required property Session session
    required property ConvertService service
    function prettyKeys(keys) {
        return String(keys || "").split(" + ").map(k => k === "PERIOD" ? "." : (k.length > 1 ? k[0] + k.slice(1).toLowerCase() : k)).join("+")
    }
    Layout.fillWidth: true
    visible: !root.service.inputPath && !root.service.result
    spacing: 2
    SectionLabel { theme: root.theme; text: "OMARCHY"; Layout.bottomMargin: 4 }
    CheckRow {
        theme: root.theme
        visible: root.service.openWith !== null
        checked: !!(root.service.openWith && root.service.openWith.enabled)
        label: "Show in Open With and app search"
        onToggled: root.service.setOpenWith(!checked)
    }
    CheckRow {
        theme: root.theme
        visible: !!(root.service.hotkey && root.service.hotkey.available && (root.service.hotkey.enabled || root.service.hotkey.free))
        checked: !!(root.service.hotkey && root.service.hotkey.enabled)
        label: "Hotkey"
        detail: root.prettyKeys(root.service.hotkey ? (root.service.hotkey.keys || root.service.hotkey.free) : "")
        onToggled: root.service.setHotkey(!checked)
    }
    CheckRow {
        theme: root.theme
        checked: root.session.prefs.offerRecordings
        label: "Offer to shrink screen recordings over 10 MB"
        onToggled: root.session.prefs.offerRecordings = !root.session.prefs.offerRecordings
    }
    Hint {
        theme: root.theme
        Layout.topMargin: 4
        text: root.service.openWithError || root.service.hotkeyError
            || "The hotkey is a marked line in ~/.config/hypr/bindings.lua. A recording over 10 MB gets a notification that opens it here."
        color: root.service.openWithError || root.service.hotkeyError ? root.theme.urgent : root.theme.faint
    }
}
