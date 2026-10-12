import QtQuick
import Quickshell
import "../../services" as Services

// The window's logic without the window: recipes, the command line and the
// fields stay in sync, pins toggle, and starting a job records the command.
ShellRoot {
    id: root
    Services.ConvertService { id: service; executable: "/bin/false" }
    Services.Session {
        id: session
        service: service
        settingsLocation: "file://" + Quickshell.env("SESSION_PREFS")
        onConversionStarted: root.started++
    }
    property int started: 0
    function fail(message) { console.error("FAIL " + message); Qt.quit() }
    Timer { interval: 50; running: true; onTriggered: root.check() }
    Timer { interval: 5000; running: true; onTriggered: root.fail("timeout") }
    function check() {
        service.metadata = { kind: "video", duration: 10, width: 1280, height: 720, fps: 30, bytes: 20000000, has_audio: true }
        session.resetRecipes()
        if (session.screen !== "recipes") return fail("screen " + session.screen)
        if (!session.matched.rows.length) return fail("no recipes")
        if (session.formatValue !== session.matched.rows[0].fields.format) return fail("first recipe not applied")

        session.editCommand("webm 2mb")
        var row = session.matched.rows[0]
        if (row.fields.format !== "WebM" || String(row.fields.size) !== "2") return fail("typed recipe " + JSON.stringify(row.fields))
        if (!session.canRunSelected) return fail("typed recipe cannot run")

        session.toggleAdvanced()
        if (session.screen !== "settings" || session.formatValue !== "WebM" || session.sizeText !== "2") return fail("settings did not take the recipe")
        if (session.commandText.indexOf("webm") !== 0) return fail("line not synced: " + session.commandText)
        session.sizeText = "7"
        session.syncCommand()
        if (session.commandText.indexOf("7mb") < 0) return fail("field edit did not rewrite the line: " + session.commandText)
        session.editCommand("gif 3mb")
        if (session.formatValue !== "GIF" || session.sizeText !== "3") return fail("typing did not fill the fields")

        session.togglePin()
        if (!session.activePinned) return fail("pin")
        session.togglePin()
        if (session.activePinned) return fail("unpin")

        session.startConversion()
        if (root.started !== 1) return fail("conversionStarted not emitted")
        if (session.jobCommand.indexOf("gif") !== 0 || session.prefs.lastVideoCommand !== session.jobCommand) return fail("command not recorded: " + session.jobCommand)
        if (service.operation !== "convert") return fail("service not started: " + service.operation)
        if (session.jobLimitBytes <= 0) return fail("limit " + session.jobLimitBytes)
        service.cancel()
        session.clear()
        if (service.metadata !== null || service.inputPath !== "" || session.idleWithFile) return fail("clear left a file")
        console.log("PASS session keeps recipes, line and fields in sync")
        Qt.quit()
    }
}
