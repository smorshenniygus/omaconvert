pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

// Async bounded previews (DEV-04): the source thumbnail and the result
// thumbnail, each a PreviewSlot with one fixed cache file, so temp previews
// never accumulate: at most src-preview.png + res-preview.png. The files are
// owner-only (0600 in a 0700 folder) and are deleted as soon as the preview
// is cleared or the window closes; leftovers from an earlier session are
// deleted at start.
Item {
    id: root
    required property string executable

    // Never a shared folder such as /tmp: the backend refuses a preview
    // folder that is not the user's own.
    readonly property string instanceId: "p" + Quickshell.processId + "-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
    readonly property string cacheBase: (Quickshell.env("XDG_CACHE_HOME")
        || (Quickshell.env("HOME") + "/.cache")) + "/omaconvert/previews/" + root.instanceId
    readonly property string sourcePath: cacheBase + "/src-preview.png"
    readonly property string resultPath: cacheBase + "/res-preview.png"

    readonly property alias sourceUrl: source.url
    readonly property alias resultUrl: result.url
    readonly property alias sourceLoading: source.loading
    readonly property alias resultLoading: result.loading
    readonly property alias sourceWidth: source.imageWidth
    readonly property alias sourceHeight: source.imageHeight
    readonly property alias resultWidth: result.imageWidth
    readonly property alias resultHeight: result.imageHeight

    // `draft`: the keyframe at or before `position` (fast, while a handle is
    // dragged); the exact frame is requested again on release. `meta`: the
    // probe event of `inputPath`, so the backend need not probe it again.
    function requestSource(inputPath, position, draft, meta) {
        // An omitted position asks for a representative frame; explicit zero
        // means the first frame and must neither share its key nor omit the seek.
        var hasPosition = position !== undefined && position !== null
        var pos = hasPosition ? Number(position) : 0
        var args = hasPosition ? ["--preview-position", String(pos)] : []
        if (draft && hasPosition) args.push("--preview-fast")
        if (meta && typeof meta === "object") args.push("--preview-meta", JSON.stringify(meta))
        source.request(inputPath, inputPath + "@" + (hasPosition ? pos.toFixed(1) : "default")
                       + (draft && hasPosition ? "~draft" : ""), args)
    }
    function requestResult(inputPath) { result.request(inputPath, inputPath, []) }
    function clearSource() { source.clear() }
    function clearResult() { result.clear() }
    function clearAll() { clearSource(); clearResult() }

    PreviewSlot {
        id: source
        executable: root.executable
        path: root.sourcePath
        keepFrameForSameInput: true
    }
    PreviewSlot {
        id: result
        executable: root.executable
        path: root.resultPath
    }
    Component.onCompleted: clearAll()
}
