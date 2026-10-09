import QtQuick
import QtTest
import "../../components" as Components

// Segments never assigns `value`, so the caller's binding survives clicks:
// two groups sharing one format (video MP4 / image PNG) keep exactly one
// highlight, a second click on an earlier choice works, and outside changes
// (typed command, recipe) move the highlight.
TestCase {
    name: "OmaConvertSegments"
    width: 600
    height: 200
    when: windowShown
    visible: true   // TestCase is hidden by default; clicks need a visible tree

    property string formatValue: "mp4"

    Column {
        Components.Segments {
            id: video
            options: ["gif", "mp4", "webm"]
            value: options.indexOf(formatValue) >= 0 ? formatValue : ""
            onChanged: v => formatValue = v
        }
        Components.Segments {
            id: image
            options: ["png", "jpg", "webp"]
            value: options.indexOf(formatValue) >= 0 ? formatValue : ""
            onChanged: v => formatValue = v
        }
    }

    function cellAt(group, index) {
        var row = group.children[0]
        var cell = null
        for (var i = 0; i < row.children.length; i++)
            if (row.children[i].index === index && row.children[i].modelData !== undefined) cell = row.children[i]
        verify(cell !== null, "cell " + index)
        return cell
    }

    function init() { formatValue = "mp4" }

    function test_clicksKeepBothGroupsInSync() {
        mouseClick(cellAt(image, 0))
        compare(formatValue, "png")
        compare(image.value, "png")
        compare(video.value, "", "the video group must lose its highlight")
        mouseClick(cellAt(video, 1))
        compare(formatValue, "mp4", "a second click on MP4 must work")
        compare(video.value, "mp4")
        compare(image.value, "")
    }

    function test_keyboardPickFollowsModel() {
        video.forceActiveFocus()
        keyClick(Qt.Key_Right)
        compare(formatValue, "webm")
        compare(video.value, "webm")
        keyClick(Qt.Key_Left)
        compare(video.value, "mp4")
    }

    function test_outsideChangeMovesHighlight() {
        mouseClick(cellAt(video, 0))
        compare(video.value, "gif")
        formatValue = "jpg"          // e.g. typed "jpg 200kb" or a recipe
        compare(video.value, "")
        compare(image.value, "jpg")
    }
}
