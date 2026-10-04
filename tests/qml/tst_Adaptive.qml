import QtQuick
import QtTest
import "../../components" as Components

// Adaptive layout: Before/After sit side by side on wide windows and
// stack vertically on narrow ones (Flow wraps when a child stops fitting).
TestCase {
    name: "OmaConvertAdaptive"
    width: 800
    height: 600
    visible: false

    Components.ResultView {
        id: wide
        result: ({path: "/tmp/a.gif", bytes: 1000, width: 320, height: 240, fps: 10.0})
        sourcePreview: "before"
        resultPreview: "after"
        width: 900
    }
    Components.ResultView {
        id: narrow
        result: ({path: "/tmp/a.gif", bytes: 1000, width: 320, height: 240, fps: 10.0})
        sourcePreview: "before"
        resultPreview: "after"
        width: 420
    }

    function findByTitle(item, title) {
        if (item && item.title === title) return item
        var lists = [item.children || [], (item.data || []), (item.resources || [])]
        for (var l = 0; l < lists.length; l++) {
            for (var i = 0; i < lists[l].length; i++) {
                var found = findByTitle(lists[l][i], title)
                if (found) return found
            }
        }
        return null
    }

    function test_sideBySideWhenWide() {
        wait(200)
        var before = findByTitle(wide, "Before")
        var after = findByTitle(wide, "After")
        verify(before && after, "both previews exist")
        // Same row: vertical overlap, horizontally apart.
        verify(Math.abs(before.y - after.y) < 4, "same row y=" + before.y + " vs " + after.y)
        verify(after.x > before.x + before.width / 2, "after is to the right")
        verify(before.width < 500, "bounded width, got " + before.width)
    }
    function test_stackedWhenNarrow() {
        wait(200)
        var before = findByTitle(narrow, "Before")
        var after = findByTitle(narrow, "After")
        verify(before && after, "both previews exist")
        verify(after.y > before.y + before.height / 2, "after is below before")
        verify(Math.abs(after.width - 420) < 2, "full width, got " + after.width)
    }
}
