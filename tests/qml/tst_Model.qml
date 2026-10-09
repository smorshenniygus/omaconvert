import QtQuick
import QtTest
import "../../services/Model.js" as Model
TestCase {
    name: "OmaConvertModel"
    function test_mediaKinds() {
        verify(Model.outputFormats("image").indexOf("PNG") >= 0)
        compare(Model.outputFormats("image").indexOf("MP4"), -1)
        verify(Model.outputFormats("video").indexOf("MOV") >= 0)
        verify(Model.stillFormat("WebP"))
        verify(!Model.stillFormat("GIF"))
        verify(Model.mediaDescription({kind:"image",width:30,height:20,bytes:100}).indexOf("fps") === -1)
        var clip = {kind:"video",width:1920,height:1080,duration:5,fps:30,bytes:1000}
        compare(Model.mediaDescription(clip).indexOf("HDR"), -1)
        clip.transfer = "arib-std-b67"
        verify(Model.mediaDescription(clip).indexOf("  ·  HDR  ·  ") > 0)
    }
    function test_fileUrls() {
        var path = "/tmp/Отпуск на море [5] #?.mp4"
        compare(Model.localPath(Model.fileUri(path)), path)
        compare(Model.localPath("https://example.org/video.mp4"), "")
        compare(Model.localPath("file://other-host/tmp/a.mp4"), "")
        compare(Model.localPath("file:///tmp/%broken"), "")
    }
    function test_sizeValidation() {
        verify(Model.validSize("50"))
        verify(Model.validSize("0.5"))
        verify(!Model.validSize("0"))
        verify(!Model.validSize("Infinity"))
        verify(!Model.validSize("5MB"))
        verify(!Model.validSize("-3"))
    }
    function test_commandArguments() {
        var path = "/tmp/Отпуск на море [5];$(echo nope).mp4"
        var args = Model.arguments(path, "gif", "target", "50", "MB", "balanced", "motion")
        compare(args[0], path)
        compare(args[args.indexOf("--max-size") + 1], "50MB")
        compare(Model.arguments(path,"mp4","quick","50","MB","small","detail").indexOf("--max-size"), -1)
    }
    function test_eventParsing() {
        compare(Model.eventFromLine("garbage"), null)
        compare(Model.eventFromLine("[]"), null)
        compare(Model.eventFromLine('{"event":"encoding","progress":0.4}').progress, 0.4)
        compare(Model.eventFromLine('{"event":"preview","width":200}').width, 200)
    }
    function test_previewHelpers() {
        compare(Model.previewSize(), 320)
        compare(Model.dimensionsText(1920, 1080), "1920\u00d71080")
        compare(Model.dimensionsText(0, 0), "")
        var text = Model.savingsText(10000000, 4000000)
        verify(text.indexOf("10.00 MB") >= 0)
        verify(text.indexOf("4.00 MB") >= 0)
        verify(text.indexOf("60%") >= 0)
        compare(Model.savingsText(0, 10), "")
    }
    function test_trimHelpers() {
        compare(Model.timeText(0), "0:00.0")
        compare(Model.timeText(3.25), "0:03.2")
        compare(Model.timeText(65.7), "1:05.7")
        compare(Model.trimLabel(2, 9.5, 12).indexOf("0:02.0") >= 0, true)
        var full = Model.trimArgs(0, 12, 12)
        compare(full.length, 0)
        var part = Model.trimArgs(2.5, 9, 12)
        compare(part[part.indexOf("--trim-start") + 1], "2.5")
        compare(part[part.indexOf("--trim-end") + 1], "9")
        compare(Model.trimArgs(0, 5, 0).length, 0)
        var args = Model.arguments("/tmp/a.mp4", "mp4", "quick", "50", "MB", "balanced", "detail", 1, 5, 12)
        compare(args[args.indexOf("--trim-start") + 1], "1")
        compare(args[args.indexOf("--trim-end") + 1], "5")
        var plain = Model.arguments("/tmp/a.mp4", "mp4", "quick", "50", "MB", "balanced", "detail", 0, 0, 12)
        verify(plain.indexOf("--trim-start") === -1)
    }
    function test_outputFolder() {
        var folder = "/tmp/Папка #1 [x] 100%;$(nope)"
        var args = Model.arguments("/tmp/a.mp4", "gif", "quick", "50", "MB", "balanced", "motion", 0, 0, 12, folder)
        compare(args[args.indexOf("--output-dir") + 1], folder)
        compare(Model.arguments("/tmp/a.mp4", "gif", "quick", "50", "MB", "balanced", "motion", 0, 0, 12, "").indexOf("--output-dir"), -1)
        compare(Model.dirname("/home/u/Видео/clip.mp4"), "/home/u/Видео")
        compare(Model.dirname("/clip.mp4"), "/")
        compare(Model.folderLabel("/home/u/Videos", "/home/u"), "~/Videos")
        compare(Model.folderLabel("/home/user2/x", "/home/u"), "/home/user2/x")
        var long = Model.folderLabel("/mnt/" + "a".repeat(80), "/home/u", 20)
        compare(long.length, 20)
        compare(long.charAt(0), "\u2026")
    }
    function test_payloadPaths() {
        compare(Model.localPath("/tmp/a #1 100%.mp4"), "/tmp/a #1 100%.mp4")
        compare(Model.localPath("file:///tmp/a%20%231%20100%25.mp4"), "/tmp/a #1 100%.mp4")
        compare(Model.localPath("file://host/tmp/a.mp4"), "")
        compare(Model.localPath("file://localhost/tmp/a%20b.mp4"), "/tmp/a b.mp4")
        compare(Model.localPath("https://example.com/a.mp4"), "")
        compare(Model.localPath("relative.mp4"), "")
    }
    function reducedCaps() {
        return {
            event: "capabilities",
            menus: { video: ["gif", "mp4", "webm", "webp"], image: ["png", "webp", "gif"] },
            input_extensions: ["mp4", "png"],
            formats: [
                { id: "gif", label: "GIF", available: true, missing: [] },
                { id: "mp4", label: "MP4", available: true, missing: [], audio: true, audio_missing: [] },
                { id: "webm", label: "WebM", available: true, missing: [], audio: false, audio_missing: ["libopus"] },
                { id: "png", label: "PNG", available: true, missing: [] },
                { id: "webp", label: "WebP", available: false, missing: ["libwebp"] }
            ]
        }
    }
    function test_capabilities() {
        var caps = reducedCaps()
        compare(Model.outputFormats("video", caps), ["GIF", "MP4", "WebM"])
        compare(Model.outputFormats("image", caps), ["PNG", "GIF"])
        compare(Model.outputFormats("image", null), Model.FALLBACK_IMAGE)
        compare(Model.outputFormats("video", null), Model.FALLBACK_VIDEO)
        compare(Model.unavailableText("image", caps), "Not available in this FFmpeg build: WebP (libwebp).")
        compare(Model.unavailableText("image", null), "")
        var sound = { kind: "video", audio: true }
        verify(Model.audioProblem("WebM", sound, caps).indexOf("libopus") > 0)
        compare(Model.audioProblem("WebM", { kind: "video", audio: false }, caps), "")
        compare(Model.audioProblem("MP4", sound, caps), "")
        compare(Model.audioProblem("WebM", sound, null), "")
        compare(Model.pickerExtensions(caps), "mp4 png")
        verify(Model.pickerExtensions(null).indexOf("heic") > 0)
    }
    function test_commandParsing() {
        var video = Model.commandFormats("video", null)
        var p = Model.parseCommand("gif 30mb", "video", video)
        compare(p.fields.format, "GIF"); compare(p.fields.size, "30"); compare(p.fields.unit, "MB"); compare(p.fields.mode, "target")
        p = Model.parseCommand("гифку до 20 мб детали", "video", video)
        compare(p.fields.format, "GIF"); compare(p.fields.size, "20"); compare(p.fields.preference, "detail")
        p = Model.parseCommand("WebM 0,5 MB", "video", video)
        compare(p.fields.size, "0.5")
        p = Model.parseCommand("png 500k", "image", Model.commandFormats("image", null))
        compare(p.fields.unit, "KB"); compare(p.fields.size, "500")
        p = Model.parseCommand("png frames 10fps", "video", video)
        compare(p.fields.format, Model.SEQUENCE); compare(p.fields.sequenceFps, 10)
        compare(Model.parseCommand("кадр", "video", video).fields.format, "PNG")
        compare(Model.parseCommand("mp4 quick high", "video", video).fields.preset, "high")
        compare(Model.parseCommand("mp4 quick balanced", "video", video).fields.preset, "balanced")
        compare(Model.parseCommand("gif 50mb balanced", "video", video).fields.preference, "balanced")
        // A quality word next to a size keeps the size; "quick" drops it, visibly.
        p = Model.parseCommand("mp4 25mb high", "video", video)
        compare(p.fields.mode, "target")
        compare(p.fields.size, "25")
        compare(p.chips.map(c => c.text + (c.ok ? "" : " ✗")), ["MP4", "≤ 25 MB", "high ✗"])
        compare(Model.parseCommand("mp4 high", "video", video).fields.mode, "quick")
        p = Model.parseCommand("mp4 25mb quick", "video", video)
        compare(p.fields.mode, "quick")
        compare(p.chips.map(c => c.text + (c.ok ? "" : " ✗")), ["MP4", "≤ 25 MB ✗", "quick"])
        // A frame rate applies to a PNG sequence only.
        p = Model.parseCommand("gif 10fps", "video", video)
        compare(p.fields.sequenceFps, undefined)
        compare(p.chips.map(c => c.text + (c.ok ? "" : " ✗")), ["GIF", "10 fps ✗"])
        compare(Model.parseCommand("png frames 10mb", "video", video).chips.map(c => c.ok), [true, false])
        // Unknown words are reported, never guessed.
        p = Model.parseCommand("gif please", "video", video)
        compare(p.rest, ["please"])
        verify(p.chips.some(c => c.text === "please" && !c.ok))
        // A format the input cannot use is named, not dropped silently.
        p = Model.parseCommand("mp4", "image", Model.commandFormats("image", null))
        compare(p.unknownFormat, "MP4"); compare(p.fields.format, undefined)
        compare(Model.parseCommand("png frames", "image", Model.commandFormats("image", null)).unknownFormat, Model.SEQUENCE)
    }
    function test_commandRoundTrip() {
        var cases = [
            ["video", { format: "GIF", mode: "target", size: "50", unit: "MB", preference: "motion", preset: "balanced", sequenceFps: 0 }],
            ["video", { format: "MP4", mode: "quick", size: "50", unit: "MB", preference: "balanced", preset: "high", sequenceFps: 0 }],
            ["video", { format: "JPG", mode: "target", size: "300", unit: "KB", preference: "balanced", preset: "balanced", sequenceFps: 0 }],
            ["video", { format: Model.SEQUENCE, mode: "quick", size: "50", unit: "MB", preference: "balanced", preset: "balanced", sequenceFps: 5 }],
            ["image", { format: "WebP", mode: "quick", size: "50", unit: "MB", preference: "balanced", preset: "small", sequenceFps: 0 }]
        ]
        for (var i = 0; i < cases.length; i++) {
            var kind = cases[i][0], fields = cases[i][1]
            var text = Model.commandText(fields, kind)
            var back = Model.completeFields(Model.parseCommand(text, kind, Model.commandFormats(kind, null)).fields, kind, { duration: 8 })
            compare(Model.commandText(back, kind), text, text)
            compare(back.format, fields.format, text)
            compare(back.mode, fields.mode, text)
        }
    }
    function test_recipesFollowTheFile() {
        var short = { kind: "video", duration: 8, fps: 30 }
        compare(Model.recipes("video", short, null, "", 8).map(r => r.command), ["gif 50mb", "mp4 10mb", "webm quick", "png frame"])
        var long = Model.recipes("video", { kind: "video", duration: 252, fps: 30 }, null, "", 252)
        compare(long[0].command, "mp4 25mb")
        verify(long.some(r => r.fields.format === "GIF" && r.note !== ""))
        compare(Model.recipes("video", { kind: "video", duration: 0, fps: 10 }, null, "", 0).map(r => r.fields.mode), ["quick", "quick", "quick"])
        compare(Model.recipes("image", { kind: "image" }, null, "", 0).map(r => r.fields.format), ["WebP", "PNG", "JPG"])
        // Last used goes first, once, marked.
        var withLast = Model.recipes("video", short, null, "mp4 10mb", 8)
        compare(withLast[0].command, "mp4 10mb"); verify(withLast[0].last)
        compare(withLast.filter(r => r.command === "mp4 10mb").length, 1)
        // A stale last command for a format this FFmpeg lost is skipped.
        compare(Model.recipes("image", { kind: "image" }, reducedCaps(), "webp quick", 0).map(r => r.fields.format), ["PNG"])
        // Sound that the format cannot keep blocks the recipe with a reason.
        var sound = Model.recipes("video", { kind: "video", duration: 8, fps: 30, audio: true }, reducedCaps(), "webm quick", 8)
        verify(sound[0].problem.indexOf("libopus") > 0)
        verify(Model.recipeDetail(Model.completeFields({ format: Model.SEQUENCE, sequenceFps: 10 }, "video", short), "video", short, 2).indexOf("20 PNG") > 0)
    }
    function test_matchRecipes() {
        var media = { kind: "video", duration: 8, fps: 30 }
        compare(Model.matchRecipes("", "video", media, null, "", 8).rows.length, 4)
        var gif = Model.matchRecipes("gif", "video", media, null, "", 8)
        compare(gif.rows.map(r => r.command), ["gif 50mb"])
        var typed = Model.matchRecipes("gif 30mb", "video", media, null, "", 8)
        compare(typed.rows[0].command, "gif 30mb"); verify(typed.rows[0].custom)
        var none = Model.matchRecipes("tiff frames", "image", { kind: "image" }, null, "", 0)
        compare(none.rows.length, 0); verify(none.note.indexOf("not available") > 0)
        compare(Model.matchRecipes("blah", "video", media, null, "", 8).rows.length, 0)
        compare(Model.matchRecipes("гифку до 20 мб пожалуйста", "video", media, null, "", 8).rows[0].command, "gif 20mb")
        compare(Model.recipeTitle(Model.completeFields({ format: "WebP" }, "image", null), "image"), "WebP")
        compare(Model.recipeTitle(Model.completeFields({ format: "MP4" }, "video", media), "video"), "MP4  ·  quick")
    }
    function test_formatGroups() {
        var video = Model.formatGroups("video", null)
        compare(video.map(g => g.title), ["Video", "One frame", "All frames"])
        compare(video[0].items, ["GIF", "MP4", "WebM", "MKV", "MOV"])
        compare(video[2].items, [Model.SEQUENCE])
        compare(Model.formatGroups("image", null)[0].items, Model.FALLBACK_IMAGE)
        verify(Model.formatGroups("image", null)[0].items.indexOf(Model.SEQUENCE) < 0)
    }
    function test_sequenceArguments() {
        var args = Model.arguments("/v.mp4", "png", "target", "50", "MB", "balanced", "balanced", 0, 0, 8, "", 10)
        verify(args.indexOf("--sequence") > 0)
        compare(args[args.indexOf("--sequence-fps") + 1], "10")
        compare(args.indexOf("--max-size"), -1)
        compare(Model.arguments("/v.mp4", "png", "quick", "50", "MB", "balanced", "balanced", 0, 0, 8, "", 0).indexOf("--sequence-fps"), -1)
        compare(Model.arguments("/v.mp4", "png", "quick", "50", "MB", "balanced", "balanced", 0, 0, 8, "", null).indexOf("--sequence"), -1)
    }
    function test_sizesAndOutputNames() {
        compare(Model.sizeLabel(200000), "200 KB")
        compare(Model.sizeLabel(10000000), "10 MB")
        compare(Model.sizeLabel(1500000), "1.5 MB")
        compare(Model.limitBytes("10", "MB"), 10000000)
        compare(Model.limitBytes("0.5", "KB"), 500)
        compare(Model.limitBytes("abc", "MB"), 0)
        compare(Model.compactSize(22298255), "22.3 MB")
        compare(Model.compactSize(137850), "138 KB")
        var gif = { format: "GIF", mode: "target", size: "10", unit: "MB" }
        compare(Model.outputName("/v/sunset-at-sea.mp4", gif), "sunset-at-sea-10mb.gif")
        compare(Model.outputName("/v/photo.png", { format: "JPG", mode: "target", size: "200", unit: "KB" }), "photo-200kb.jpg")
        compare(Model.outputName("/v/a.mov", { format: "MP4", mode: "target", size: "1.5", unit: "MB" }), "a-1-5mb.mp4")
        compare(Model.outputName("/v/a.mov", { format: "WebM", mode: "quick", size: "10", unit: "MB" }), "a.webm")
        compare(Model.outputName("/v/a.mov", { format: Model.SEQUENCE, mode: "quick" }), "a-frames/")
    }
    function test_pinnedRecipesAndBatch() {
        var short = { kind: "video", duration: 8, fps: 30 }
        var rows = Model.recipes("video", short, null, "", 8, ["mp4 25mb", "gif 10mb"])
        compare(rows.map(r => r.command).slice(0, 2), ["mp4 25mb", "gif 10mb"])
        verify(rows[0].pinned && rows[1].pinned && !rows[2].pinned)
        compare(rows.length, 5)
        compare(Model.togglePinned(["gif 10mb"], "jpg 200kb"), ["gif 10mb", "jpg 200kb"])
        compare(Model.togglePinned(["gif 10mb", "jpg 200kb"], "gif 10mb"), ["jpg 200kb"])
        compare(Model.togglePinned(["a", "b", "c", "d", "e", "f"], "g"), ["b", "c", "d", "e", "f", "g"])
        compare(Model.parsePinned("[\"gif 10mb\", 3]"), ["gif 10mb"])
        compare(Model.parsePinned("oops"), [])
        compare(Model.batchArguments(["/a.png", "/b c.png"], "jpg", "target", "200", "KB", "balanced", "balanced", "", null),
                ["/a.png", "/b c.png", "--format", "jpg", "--preset", "balanced", "--preference", "balanced", "--max-size", "200KB", "--batch"])
        // What is left of a selection may be one file: still a batch.
        compare(Model.batchArguments(["/a.png"], "webp", "quick", "50", "MB", "small", "balanced", "/out", null),
                ["/a.png", "--format", "webp", "--preset", "small", "--preference", "balanced", "--output-dir", "/out", "--batch"])
    }
}
