import CoreGraphics
import Foundation
import Testing
@testable import iosapp

// Rotation keeps the photo under the middle of the screen in the
// middle of the new viewport. The month sidebar only changes width,
// so these tests cover the center anchor and not the top-photo path.
struct TimelineViewportCenterAnchorTests {
    // A portrait grid shows several rows. The anchor is the photo
    // the viewport center sits on, not the row at the top.
    @Test func selectsTheCellUnderTheViewportCenter() {
        let anchor = TimelineViewportCenterAnchor.capturing(
            itemFrames: stackedCells(count: 3, side: 100),
            viewportCenter: CGPoint(x: 50, y: 151)
        )
        #expect(anchor?.itemIndex == 1)
        #expect(anchor?.fractionFromItemTop == 0.5)
    }

    // A bounds change can ask for the center before the cells have
    // moved. Snapping to the nearest far-away photo locks the jump,
    // so that sample is ignored and the previous anchor stays.
    @Test func ignoresACenterThatIsNotNearAnyCell() {
        let anchor = TimelineViewportCenterAnchor.capturing(
            itemFrames: stackedCells(count: 3, side: 100),
            viewportCenter: CGPoint(x: 50, y: -400)
        )
        #expect(anchor == nil)
    }

    // The center can land in the 1pt gap between rows. The nearest
    // photo is the anchor so the gap does not drop the rotation hold.
    @Test func usesTheNearestCellWhenTheCenterFallsInTheGap() {
        let anchor = TimelineViewportCenterAnchor.capturing(
            itemFrames: stackedCells(count: 3, side: 100),
            viewportCenter: CGPoint(x: 50, y: 100.75)
        )
        #expect(anchor?.itemIndex == 1)
        #expect(anchor?.fractionFromItemTop == 0)
    }

    // Column count and cell size both change on rotation. The same
    // fraction of the anchor photo has to sit on the new viewport
    // center, or the surrounding photos slide to a different place.
    @Test func keepsTheSameFractionOnTheNewViewportCenter() {
        let portrait = TimelineViewportCenterAnchor.contentOffsetY(
            itemMinY: 400,
            itemHeight: 100,
            fractionFromItemTop: 0.25,
            viewportHeight: 800,
            contentHeight: 5000,
            topInset: 50,
            bottomInset: 40
        )
        #expect(portrait == 25)
        #expect(portrait + 800 / 2 == 400 + 0.25 * 100)

        let landscape = TimelineViewportCenterAnchor.contentOffsetY(
            itemMinY: 250,
            itemHeight: 140,
            fractionFromItemTop: 0.25,
            viewportHeight: 400,
            contentHeight: 3000,
            topInset: 0,
            bottomInset: 20
        )
        #expect(landscape == 85)
        #expect(landscape + 400 / 2 == 250 + 0.25 * 140)
    }

    // The first and last rows cannot reach the middle of a tall
    // viewport. Clamping keeps the offset inside the range UIKit scrolls.
    @Test func clampsWhenTheAnchorCannotStayCentered() {
        let firstRow = TimelineViewportCenterAnchor.contentOffsetY(
            itemMinY: 0,
            itemHeight: 100,
            fractionFromItemTop: 0.2,
            viewportHeight: 800,
            contentHeight: 5000,
            topInset: 50,
            bottomInset: 40
        )
        #expect(firstRow == -50)

        let lastRow = TimelineViewportCenterAnchor.contentOffsetY(
            itemMinY: 4900,
            itemHeight: 100,
            fractionFromItemTop: 0.8,
            viewportHeight: 800,
            contentHeight: 5000,
            topInset: 50,
            bottomInset: 40
        )
        #expect(lastRow == 4240)
    }

    // The month sidebar is 64pt wide and does not change height.
    // That resize keeps the top photo.
    @Test func keepsTheTopPhotoForTheSidebarWidthChange() {
        #expect(!TimelineViewportCenterAnchor.preservesCenter(widthDelta: 64, heightDelta: 0))
    }

    // In landscape the sidebar also gives back the side safe area, so
    // the grid narrows by more than the sidebar's own 64pt. That is
    // still a top-photo resize. A rotation is several hundred points.
    @Test func keepsTheTopPhotoWhenTheLandscapeSidebarOpens() {
        #expect(!TimelineViewportCenterAnchor.preservesCenter(widthDelta: 140, heightDelta: 0))
    }

    // Rotation changes both axes, including the first animated frame
    // where each axis has only moved a little.
    @Test func keepsTheMiddlePhotoWhenBothAxesChange() {
        #expect(TimelineViewportCenterAnchor.preservesCenter(widthDelta: 20, heightDelta: 18))
    }

    // A rotation frame can change width before height. A jump wider
    // than the sidebar is still a rotation.
    @Test func keepsTheMiddlePhotoWhenTheWidthJumps() {
        #expect(TimelineViewportCenterAnchor.preservesCenter(widthDelta: 400, heightDelta: 0))
    }

    // The first rotation frame can change height before width. The
    // sidebar never changes height, so this still keeps the middle photo.
    @Test func keepsTheMiddlePhotoWhenTheHeightChanges() {
        #expect(TimelineViewportCenterAnchor.preservesCenter(widthDelta: 0, heightDelta: 18))
    }

    // A one-point layout correction is not a rotation.
    @Test func ignoresASmallSingleAxisChange() {
        #expect(!TimelineViewportCenterAnchor.preservesCenter(widthDelta: 0, heightDelta: 2))
        #expect(!TimelineViewportCenterAnchor.preservesCenter(widthDelta: 2, heightDelta: 0))
    }

    // One column of square cells with the timeline's 1pt row gap.
    private func stackedCells(count: Int, side: CGFloat) -> [(index: Int, frame: CGRect)] {
        (0..<count).map { index in
            let originY = CGFloat(index) * (side + 1)
            return (index, CGRect(x: 0, y: originY, width: side, height: side))
        }
    }
}
