import QtQuick
import QtTest
import "../../components" as Components

// TrimBar: range setters mirror to start/end; scrub requests follow the
// moved handle (debounced noteMove, immediate scrubNow); moveActive
// clamps into [0, duration] and keeps a 0.1s minimum gap.
TestCase {
    name: "OmaConvertTrim"
    width: 600
    height: 400

    Components.TrimBar {
        id: trim
        duration: 12
        width: 500
    }
    SignalSpy {
        id: scrubSpy
        target: trim
        signalName: "scrubRequested"
    }

    function sliderItem() {
        return trim.children[1]
    }

    function test_rangeSetters() {
        trim.setRange(2.5, 9)
        compare(trim.startTime, 2.5)
        compare(trim.endTime, 9)
        verify(trim.valid)
        trim.reset()
        compare(trim.startTime, 0)
        compare(trim.endTime, 12)
    }

    function test_scrubRouting() {
        // A move gives a draft frame quickly, then the exact frame once it rests.
        scrubSpy.clear()
        trim.noteMove(4)
        tryCompare(scrubSpy, "count", 2, 2000)
        compare(scrubSpy.signalArguments[0][0], 4)
        compare(scrubSpy.signalArguments[0][1], true)
        compare(scrubSpy.signalArguments[1][0], 4)
        compare(scrubSpy.signalArguments[1][1], false)
        // Release asks for the exact frame at once and cancels a pending draft.
        trim.noteMove(5)
        trim.scrubNow(7)
        compare(scrubSpy.count, 3)
        compare(scrubSpy.signalArguments[2][0], 7)
        compare(scrubSpy.signalArguments[2][1], false)
        wait(700)
        compare(scrubSpy.count, 3)
    }

    function test_moveActiveClamps() {
        var slider = sliderItem()
        trim.setRange(2, 10)
        trim.activeHandle = "first"
        slider.moveActive(-5)
        compare(trim.startTime, 0)
        slider.moveActive(99)
        compare(trim.startTime, 9.9)
        trim.activeHandle = "second"
        slider.moveActive(0.05)
        compare(trim.endTime, 10)
        slider.moveActive(99)
        compare(trim.endTime, 12)
    }
}
