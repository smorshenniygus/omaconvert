.pragma library

// Version of the loaded interface. Kept equal to manifest.json and
// lib/__init__.py by tests/test_version.py; compared at runtime with the
// backend version to detect a shell still running stale cached QML.
var VERSION = "1.2.2"
// Fallback when the host does not inject `manifest`; equal to manifest.json.
var PLUGIN_ID = "io.github.smorshenniygus.omaconvert"

function localPath(value) {
    var text = String(value || "")
    if (text.indexOf("/") === 0) return text
    if (text.indexOf("file:///") !== 0) return ""
    try { return decodeURIComponent(text.slice(7)) } catch (_) { return "" }
}
function fileUri(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}
function validSize(text) {
    return /^\d+(\.\d+)?$/.test(String(text)) && isFinite(Number(text)) && Number(text) > 0
}
// sequenceFps: undefined/null for a single file; 0 (every frame) or a rate
// writes a PNG sequence folder instead (format must be "png").
// Inside other functions `arguments` is the JS arguments object, so the
// implementation lives in cliArguments and this name stays for callers.
function arguments(path, format, mode, size, unit, preset, preference, trimStart, trimEnd, duration, outputDir, sequenceFps) {
    return cliArguments(path, format, mode, size, unit, preset, preference, trimStart, trimEnd, duration, outputDir, sequenceFps)
}
function cliArguments(path, format, mode, size, unit, preset, preference, trimStart, trimEnd, duration, outputDir, sequenceFps) {
    var args = [path, "--format", format, "--preset", preset, "--preference", preference]
    var sequence = sequenceFps !== undefined && sequenceFps !== null
    if (mode === "target" && !sequence) args.push("--max-size", size + unit)
    if (outputDir) args.push("--output-dir", String(outputDir))
    if (sequence) {
        args.push("--sequence")
        if (Number(sequenceFps) > 0) args.push("--sequence-fps", String(sequenceFps))
    }
    return args.concat(trimArgs(trimStart, trimEnd, duration))
}
// Parent folder of an absolute path ("/" for top-level files).
function dirname(path) {
    var text = String(path || "")
    var cut = text.lastIndexOf("/")
    return cut > 0 ? text.slice(0, cut) : "/"
}
// Human folder label: home shortened to "~", long paths keep their tail.
function folderLabel(path, home, maxLength) {
    var text = String(path || "")
    var h = String(home || "")
    if (h && (text === h || text.indexOf(h + "/") === 0)) text = "~" + text.slice(h.length)
    var limit = maxLength || 48
    if (text.length > limit) text = "…" + text.slice(text.length - limit + 1)
    return text
}
function trimArgs(start, end, duration) {
    var d = Number(duration || 0)
    if (!(d > 0)) return []
    var args = []
    var s = Number(start || 0), e = Number(end)
    if (s > 0.001) args.push("--trim-start", String(Math.round(s * 1000) / 1000))
    if (e > 0 && e < d - 0.001) args.push("--trim-end", String(Math.round(e * 1000) / 1000))
    return args
}
function timeText(seconds) {
    var n = Math.max(0, Number(seconds || 0))
    var m = Math.floor(n / 60)
    var rest = n - m * 60
    var whole = Math.floor(rest)
    var tenth = Math.floor((rest - whole) * 10)
    return m + ":" + (whole < 10 ? "0" : "") + whole + "." + tenth
}
function trimLabel(start, end, duration) {
    return "Trim " + timeText(start) + " \u2013 " + timeText(end) + " of " + timeText(duration)
}
function eventFromLine(line) {
    try {
        var obj = JSON.parse(line)
        return obj && typeof obj.event === "string" ? obj : null
    } catch (_) { return null }
}
function name(path) { return String(path).split("/").pop() }
function duration(seconds) {
    var n = Math.max(0, Math.round(Number(seconds) || 0))
    return Math.floor(n / 60) + ":" + (n % 60 < 10 ? "0" : "") + n % 60
}
function megabytes(bytes) {
    var n = Number(bytes || 0)
    return n > 0 && n < 1000000 ? (n / 1000).toFixed(2) + " KB" : (n / 1000000).toFixed(2) + " MB"
}

// A target size the way it was typed: "200 KB", "10 MB", "1.5 MB" (mirrors
// lib/optimizer.size_text, which also names the output file).
function sizeLabel(bytes) {
    var n = Number(bytes || 0)
    var units = [["GB", 1e9], ["MB", 1e6], ["KB", 1e3]]
    for (var i = 0; i < units.length; i++)
        if (n >= units[i][1] || units[i][0] === "KB") return Number((n / units[i][1]).toPrecision(6)) + " " + units[i][0]
}
// Bytes of a size field, 0 when the text is not a size.
function limitBytes(size, unit) {
    return validSize(size) ? Math.floor(Number(size) * (unit === "KB" ? 1e3 : 1e6)) : 0
}
// Short size for big numbers: "22.3 MB", "138 KB".
function compactSize(bytes) {
    var n = Number(bytes || 0)
    if (n >= 1e9) return (n / 1e9).toFixed(1) + " GB"
    if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e8 ? 0 : 1) + " MB"
    return Math.max(0, Math.round(n / 1e3)) + " KB"
}
// File (or folder) the backend will create for these fields; a taken name
// later gets a number. Mirrors lib/backend._default_output.
function outputName(path, fields) {
    var file = name(path || "")
    var dot = file.lastIndexOf(".")
    var stem = dot > 0 ? file.slice(0, dot) : file
    if (!fields || !fields.format) return ""
    if (fields.format === SEQUENCE) return stem + "-frames/"
    var ext = String(fields.format).toLowerCase()
    var bytes = fields.mode === "target" ? limitBytes(fields.size, fields.unit) : 0
    if (!bytes) return stem + "." + ext
    return stem + "-" + sizeLabel(bytes).replace(" ", "").replace(".", "-").toLowerCase() + "." + ext
}

// Common upload limits offered next to the size field.
var SIZE_PRESETS = [
    { label: "discord 10", size: 10, unit: "MB" },
    { label: "x gif 15", size: 15, unit: "MB" },
    { label: "email 25", size: 25, unit: "MB" },
    { label: "web 500 kb", size: 500, unit: "KB" }
]

// Offline fallbacks until the backend answers --capabilities; mirror
// lib/formats.py (checked by tests/test_formats.py).
var FALLBACK_IMAGE = ["PNG", "JPG", "WebP", "BMP", "TIFF", "GIF"]
var FALLBACK_VIDEO = ["GIF", "MP4", "WebM", "MKV", "MOV", "PNG", "JPG", "WebP", "BMP", "TIFF"]
var FALLBACK_EXTENSIONS = "mp4 mov mkv webm avi m4v mpeg mpg ts mts m2ts wmv flv ogv 3gp gif png jpg jpeg webp bmp tif tiff avif heic heif"

function capsFormat(caps, id) {
    var list = caps && caps.formats ? caps.formats : []
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
}
// Menu labels for an input kind; formats this FFmpeg cannot write are left out.
function outputFormats(kind, caps) {
    if (!caps || !caps.menus || !caps.formats) return kind === "image" ? FALLBACK_IMAGE : FALLBACK_VIDEO
    var ids = caps.menus[kind === "image" ? "image" : "video"] || []
    var out = []
    for (var i = 0; i < ids.length; i++) {
        var f = capsFormat(caps, ids[i])
        if (f && f.available) out.push(f.label)
    }
    return out
}
// "WebP (libwebp)" style list of formats hidden from the menu, or "".
function unavailableText(kind, caps) {
    if (!caps || !caps.menus || !caps.formats) return ""
    var ids = caps.menus[kind === "image" ? "image" : "video"] || []
    var parts = []
    for (var i = 0; i < ids.length; i++) {
        var f = capsFormat(caps, ids[i])
        if (f && !f.available) parts.push(f.label + " (" + f.missing.join(", ") + ")")
    }
    return parts.length ? "Not available in this FFmpeg build: " + parts.join(", ") + "." : ""
}
// Reason the chosen format cannot keep this input's sound, or "".
function audioProblem(label, media, caps) {
    if (!media || !media.audio || media.kind === "image") return ""
    var f = capsFormat(caps, String(label || "").toLowerCase())
    if (!f || f.audio !== false) return ""
    return f.label + " with sound needs " + f.audio_missing.join(", ") + ", which this FFmpeg build does not provide. Choose MP4, MKV or MOV."
}
function pickerExtensions(caps) {
    return caps && caps.input_extensions ? caps.input_extensions.join(" ") : FALLBACK_EXTENSIONS
}
function stillFormat(format) { return ["PNG", "JPG", "WebP", "BMP", "TIFF"].indexOf(format) !== -1 }
function previewSize() { return 320 }
function savingsText(beforeBytes, afterBytes) {
    var before = Number(beforeBytes || 0)
    var after = Number(afterBytes || 0)
    if (!(before > 0) || !(after >= 0)) return ""
    var diff = before - after
    var percent = Math.round(diff / before * 100)
    var arrow = diff >= 0 ? "\u2212" + Math.abs(percent) + "%" : "+" + Math.abs(percent) + "%"
    return megabytes(before) + " \u2192 " + megabytes(after) + "  \u00b7  " + arrow
}
function dimensionsText(width, height) {
    var w = Number(width || 0), h = Number(height || 0)
    return (w > 0 && h > 0) ? w + "\u00d7" + h : ""
}
// HLG (iPhone) or PQ (HDR10); the backend tone maps these to SDR.
function isHdr(media) {
    return !!media && (media.transfer === "arib-std-b67" || media.transfer === "smpte2084")
}
function mediaDescription(media) {
    if (!media) return ""
    return media.width + "×" + media.height
        + (media.kind === "image" ? "  ·  Image" : "  ·  " + (media.duration > 0 ? duration(media.duration) : "Duration unavailable") + "  ·  " + Number(media.fps).toFixed(1) + " fps")
        + (isHdr(media) ? "  ·  HDR" : "")
        + "  ·  " + megabytes(media.bytes || media.size)
}

// ── Command line and recipes ──────────────────────────────────────────────
// The window offers ready-made recipes for the opened file and a command
// line that understands short requests such as "gif 30mb" or "png frames
// 10fps". Parsing is plain word matching: predictable, instant, offline.
// A recipe and the full settings panel share one `fields` object:
//   { format, mode: "target"|"quick", size, unit: "MB"|"KB",
//     preference: "motion"|"balanced"|"detail", preset: "small"|"balanced"|"high",
//     sequenceFps: 0 (every frame) or a rate; used only by the PNG sequence }
var SEQUENCE = "PNG sequence"
var PREFERENCES = ["motion", "balanced", "detail"]
var PRESETS = ["small", "balanced", "high"]
// Longer than this a whole-clip GIF is rarely what anyone wants.
var LONG_VIDEO_SECONDS = 60

var FORMAT_WORDS = {
    gif: "GIF", "гиф": "GIF", "гифка": "GIF", "гифку": "GIF", "гифки": "GIF",
    mp4: "MP4", webm: "WebM", mkv: "MKV", mov: "MOV",
    png: "PNG", jpg: "JPG", jpeg: "JPG", webp: "WebP", bmp: "BMP", tif: "TIFF", tiff: "TIFF"
}
var SEQUENCE_WORDS = ["sequence", "seq", "frames", "кадры", "секвенция", "последовательность"]
var FRAME_WORDS = ["frame", "still", "кадр"]
var QUICK_WORDS = ["quick", "fast", "быстро", "быстрый"]
var PRESET_WORDS = { small: "small", smaller: "small", "меньше": "small", high: "high", hq: "high", best: "high", "лучше": "high" }
var PREFERENCE_WORDS = {
    motion: "motion", smooth: "motion", "движение": "motion", "плавно": "motion",
    detail: "detail", details: "detail", sharp: "detail", "детали": "detail", "чётко": "detail", "четко": "detail"
}
var BALANCED_WORDS = ["balanced", "balance", "баланс"]
var FILLER_WORDS = ["to", "as", "into", "under", "max", "up", "до", "в", "не", "больше", "≤", "<", "<=", "size", "размер"]
var MB_WORDS = ["mb", "мб", "m", "м"]
var KB_WORDS = ["kb", "кб", "k", "к"]
var FPS_WORDS = ["fps", "к/с"]

// Formats the command line and the panel offer for an input kind.
function commandFormats(kind, caps) {
    var list = outputFormats(kind, caps).slice()
    if (kind !== "image" && list.indexOf("PNG") >= 0) list.push(SEQUENCE)
    return list
}
// Panel rows: a video offers motion formats, one frame, or every frame.
function formatGroups(kind, caps) {
    var all = commandFormats(kind, caps)
    if (kind === "image") return [{ title: "Format", items: all }]
    return [
        { title: "Video", items: all.filter(f => f !== SEQUENCE && !stillFormat(f)) },
        { title: "One frame", items: all.filter(f => stillFormat(f)) },
        { title: "All frames", items: all.filter(f => f === SEQUENCE) }
    ].filter(g => g.items.length > 0)
}
function sizeText(size, unit) { return size + " " + (unit === "KB" ? "KB" : "MB") }
function isMoving(format, kind) { return kind !== "image" && format !== SEQUENCE && !stillFormat(format) }

// Words → partial fields. `available` lists the formats this input may use;
// a recognised but unavailable one is reported instead of silently ignored.
function parseCommand(text, kind, available) {
    var words = String(text || "").toLowerCase().replace(/(\d),(\d)/g, "$1.$2").split(/\s+/).filter(w => w !== "")
    var fields = {}, rest = [], chips = []
    var named = "", sequence = false, frame = false, quick = false, balanced = false
    var size = "", unit = "", fps = 0
    for (var i = 0; i < words.length; i++) {
        var w = words[i]
        var num = w.match(/^(\d+(?:\.\d+)?)(mb|мб|m|м|kb|кб|k|к|fps|к\/с)?$/)
        if (num) {
            var suffix = num[2] || ""
            if (!suffix && i + 1 < words.length && MB_WORDS.concat(KB_WORDS, FPS_WORDS).indexOf(words[i + 1]) >= 0) suffix = words[++i]
            if (FPS_WORDS.indexOf(suffix) >= 0) fps = Number(num[1])
            else { size = String(Number(num[1])); unit = KB_WORDS.indexOf(suffix) >= 0 ? "KB" : "MB" }
        }
        else if (FORMAT_WORDS[w]) named = FORMAT_WORDS[w]
        else if (SEQUENCE_WORDS.indexOf(w) >= 0) sequence = true
        else if (FRAME_WORDS.indexOf(w) >= 0) frame = true
        else if (QUICK_WORDS.indexOf(w) >= 0) quick = true
        else if (PRESET_WORDS[w]) { fields.preset = PRESET_WORDS[w]; quick = true }
        else if (PREFERENCE_WORDS[w]) fields.preference = PREFERENCE_WORDS[w]
        else if (BALANCED_WORDS.indexOf(w) >= 0) balanced = true
        else if (FILLER_WORDS.indexOf(w) >= 0 || MB_WORDS.indexOf(w) >= 0) { }
        else rest.push(w)
    }
    var format = ""
    if (sequence) format = SEQUENCE
    else if (named) format = named
    else if (frame && kind !== "image") format = "PNG"
    var unknown = ""
    if (format && (available || []).indexOf(format) < 0) { unknown = format; format = "" }
    if (format) fields.format = format
    if (size) { fields.size = size; fields.unit = unit; fields.mode = "target" }
    if (quick) fields.mode = "quick"
    if (balanced) {
        if (fields.mode === "quick") fields.preset = "balanced"
        else fields.preference = "balanced"
    }
    if (fps > 0) fields.sequenceFps = fps
    if (format) chips.push({ text: format === SEQUENCE ? SEQUENCE : (kind !== "image" && stillFormat(format) ? "Frame → " + format : format), ok: true })
    if (unknown) chips.push({ text: unknown, ok: false })
    if (fields.mode === "target") chips.push({ text: "≤ " + sizeText(fields.size, fields.unit), ok: true })
    if (fields.mode === "quick") chips.push({ text: "quick" + (fields.preset && fields.preset !== "balanced" ? " · " + fields.preset : ""), ok: true })
    if (fields.preference) chips.push({ text: "keep " + fields.preference, ok: true })
    if (fps > 0) chips.push({ text: fps + " fps", ok: true })
    for (var r = 0; r < rest.length; r++) chips.push({ text: rest[r], ok: false })
    return { fields: fields, chips: chips, rest: rest, unknownFormat: unknown }
}

// Canonical words for complete fields; parseCommand() reads them back.
function commandText(fields, kind) {
    if (!fields || !fields.format) return ""
    if (fields.format === SEQUENCE) return "png frames" + (fields.sequenceFps > 0 ? " " + fields.sequenceFps + "fps" : "")
    var parts = [fields.format.toLowerCase()]
    if (kind !== "image" && stillFormat(fields.format)) parts.push("frame")
    if (fields.mode === "quick") {
        // A still is quick unless sized; only motion formats spell it out.
        if (!stillFormat(fields.format) || (fields.preset && fields.preset !== "balanced")) parts.push("quick")
        if (fields.preset && fields.preset !== "balanced") parts.push(fields.preset)
    } else {
        parts.push(fields.size + (fields.unit === "KB" ? "kb" : "mb"))
        if (fields.format === "GIF" && kind !== "image" && fields.preference && fields.preference !== "balanced") parts.push(fields.preference)
    }
    return parts.join(" ")
}

// Fill what a short request left out. A GIF from a video defaults to the
// flagship 50 MB target; everything else to a quick conversion.
function completeFields(partial, kind, media) {
    var p = partial || {}
    var knownLength = !media || (media.duration || 0) > 0
    var f = {
        format: p.format || "",
        mode: p.mode || (p.format === "GIF" && kind !== "image" && knownLength ? "target" : "quick"),
        size: p.size || "50", unit: p.unit || "MB",
        preference: p.preference || "balanced", preset: p.preset || "balanced",
        sequenceFps: p.sequenceFps || 0
    }
    if (f.format === SEQUENCE) f.mode = "quick"
    return f
}

function defaultCommands(kind, media) {
    if (kind === "image") return ["webp", "png 1mb", "jpg"]
    var length = media ? Number(media.duration || 0) : 0
    if (!(length > 0)) return ["gif quick", "mp4 quick", "png frame"]
    if (length > LONG_VIDEO_SECONDS) return ["mp4 25mb", "mp4 quick", "gif 50mb", "png frame"]
    return ["gif 50mb", "mp4 10mb", "webm quick", "png frame"]
}

function recipeTitle(f, kind) {
    if (f.format === SEQUENCE) return SEQUENCE + "  ·  " + (f.sequenceFps > 0 ? f.sequenceFps + " fps" : "every frame")
    var name = kind !== "image" && stillFormat(f.format) ? "Frame → " + f.format : f.format
    if (f.mode === "target") return name + " ≤ " + sizeText(f.size, f.unit)
    var preset = f.preset !== "balanced" ? f.preset : ""
    // A still has no size search to skip, so "quick" says nothing there.
    if (stillFormat(f.format)) return name + (preset ? "  ·  " + preset : "")
    return name + "  ·  quick" + (preset ? " " + preset : "")
}

// `seconds`: length that will be converted (the trimmed part of a video).
function recipeDetail(f, kind, media, seconds) {
    if (f.format === SEQUENCE) {
        var rate = media && media.fps > 0 ? (f.sequenceFps > 0 ? Math.min(f.sequenceFps, media.fps) : media.fps) : 0
        var count = Math.round(Number(seconds || 0) * rate)
        return (count > 0 ? "≈ " + count + " PNG files" : "PNG files") + " in a new folder"
    }
    if (kind !== "image" && stillFormat(f.format)) return "One still at the trim start"
    if (f.mode === "target") {
        if (f.format === "GIF" && kind !== "image")
            return "Best quality that fits  ·  " + { motion: "smooth motion first", balanced: "motion and detail balanced", detail: "sharp detail first" }[f.preference]
        return (kind === "image" ? "Scaled down until it fits" : "Two-pass encode") + "  ·  size is verified"
    }
    return { small: "Smaller file", balanced: "Balanced quality", high: "High quality" }[f.preset] + ", no size search"
}

// Reason a recipe cannot run for this input (blocks it), or "".
function recipeProblem(f, kind, media, caps) {
    var sound = audioProblem(f.format, media, caps)
    if (sound) return sound
    if (f.mode === "target" && isMoving(f.format, kind) && media && !(media.duration > 0))
        return "A size target needs a known duration. Use quick."
    if (f.mode === "target" && f.format !== SEQUENCE && !validSize(f.size)) return "Enter a size greater than zero."
    return ""
}
// Heads-up that does not block, or "".
function recipeNote(f, kind, seconds) {
    if (f.format === "JPG") return "JPEG replaces transparency with white."
    if (f.format === "GIF" && kind !== "image" && Number(seconds || 0) > LONG_VIDEO_SECONDS)
        return "Long for a GIF: pick a short part with the trim handles."
    if (f.format === SEQUENCE && Number(seconds || 0) > LONG_VIDEO_SECONDS) return "That is a lot of files; trim or lower the rate."
    return ""
}

function recipe(fields, kind, media, caps, seconds) {
    return {
        command: commandText(fields, kind), fields: fields,
        title: recipeTitle(fields, kind), detail: recipeDetail(fields, kind, media, seconds),
        problem: recipeProblem(fields, kind, media, caps), note: recipeNote(fields, kind, seconds),
        last: false, custom: false
    }
}

// Up to four recipes for the opened file, the last used one first.
function recipes(kind, media, caps, lastCommand, seconds, pinned) {
    var available = commandFormats(kind, caps)
    var pins = pinned || []
    var commands = pins.concat(lastCommand ? [lastCommand] : []).concat(defaultCommands(kind, media))
    // Pinned recipes always fit; the usual four follow them.
    var limit = Math.min(9, Math.max(4, pins.length + 3))
    var seen = {}, out = []
    for (var i = 0; i < commands.length && out.length < limit; i++) {
        var parsed = parseCommand(commands[i], kind, available)
        if (!parsed.fields.format || parsed.rest.length) continue
        var r = recipe(completeFields(parsed.fields, kind, media), kind, media, caps, seconds)
        if (seen[r.command]) continue
        seen[r.command] = true
        r.pinned = i < pins.length
        r.last = !r.pinned && i === pins.length && !!lastCommand
        out.push(r)
    }
    return out
}
// Pin or unpin a recipe command; at most six, the oldest drops off.
var MAX_PINNED = 6
function togglePinned(list, command) {
    var current = (list || []).filter(c => c !== command)
    if (current.length === (list || []).length) current.push(command)
    return current.slice(-MAX_PINNED)
}
function parsePinned(text) {
    try { var value = JSON.parse(text || "[]"); return Array.isArray(value) ? value.filter(c => typeof c === "string") : [] }
    catch (_) { return [] }
}
// Arguments for a batch: every path first, then the one recipe (no trim).
function batchArguments(paths, format, mode, size, unit, preset, preference, outputDir, sequenceFps) {
    var args = cliArguments(paths[0], format, mode, size, unit, preset, preference, 0, 0, 0, outputDir, sequenceFps)
    return [paths[0]].concat(paths.slice(1)).concat(args.slice(1))
}

// What the list shows for the typed text: matching recipes, plus the
// typed request itself on top when it is not one of them.
function matchRecipes(text, kind, media, caps, lastCommand, seconds, pinned) {
    var list = recipes(kind, media, caps, lastCommand, seconds, pinned)
    if (!String(text || "").trim()) return { rows: list, chips: [], note: "" }
    var available = commandFormats(kind, caps)
    var parsed = parseCommand(text, kind, available)
    if (parsed.unknownFormat)
        return { rows: [], chips: parsed.chips,
                 note: parsed.unknownFormat + " is not available for " + (kind === "image" ? "an image" : "a video") + ". Try " + available.join(", ") + "." }
    var keys = Object.keys(parsed.fields)
    var rows = list.filter(r => keys.every(k => String(r.fields[k]) === String(parsed.fields[k]))
        && parsed.rest.every(w => (r.title + " " + r.detail).toLowerCase().indexOf(w) >= 0))
    // Unknown words narrow the list but never hide what was understood.
    if (parsed.fields.format) {
        var typed = recipe(completeFields(parsed.fields, kind, media), kind, media, caps, seconds)
        if (!rows.some(r => r.command === typed.command)) { typed.custom = true; rows.unshift(typed) }
    }
    return { rows: rows, chips: parsed.chips, note: rows.length ? "" : "Nothing matches. Press + to set it up field by field." }
}
