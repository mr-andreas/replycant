import Foundation
import Testing
@testable import iosapp

// Verifies startup anchoring math keeps timeline launch pinned to the newest rows.
struct TimelineInitialBottomAnchorTests {
    // Ensures scrollable content starts at the maximum valid bottom offset.
    @Test func computesBottomOffsetForScrollableContent() {
        let offset = TimelineInitialBottomAnchor.targetYOffset(
            contentHeight: 1800,
            viewportHeight: 700,
            topInset: 12,
            bottomInset: 34
        )
        #expect(offset == 1134)
    }

    // Ensures short content clamps to UIKit's minimum offset instead of overscrolling.
    @Test func clampsToTopInsetWhenContentIsShort() {
        let offset = TimelineInitialBottomAnchor.targetYOffset(
            contentHeight: 400,
            viewportHeight: 700,
            topInset: 20,
            bottomInset: 12
        )
        #expect(offset == -20)
    }

    // Tab reselect and the status bar ask for the top. That is where the
    // oldest photos are, so the grid is sent to the newest row instead.
    @Test func replacesTopAnchorWithNewestRow() {
        let offset = TimelineInitialBottomAnchor.newestOffsetReplacingTopAnchor(
            requestedY: -100,
            currentY: 400,
            contentHeight: 2000,
            viewportHeight: 700,
            topInset: 100,
            bottomInset: 34,
            redirects: true,
            isUserDriven: false
        )
        #expect(offset == 1334)
    }

    // A second tap while the newest row is already on screen must not be
    // handed back to UIKit, which would scroll to the oldest row.
    @Test func staysOnNewestRowWhenTopAnchorIsRequestedThere() {
        let offset = TimelineInitialBottomAnchor.newestOffsetReplacingTopAnchor(
            requestedY: -100,
            currentY: 1334,
            contentHeight: 2000,
            viewportHeight: 700,
            topInset: 100,
            bottomInset: 34,
            redirects: true,
            isUserDriven: false
        )
        #expect(offset == 1334)
    }

    // A library that fits on one screen has nowhere newer to go, so the
    // system's own top request is already the right place.
    @Test func leavesTopAnchorAloneWhenContentFits() {
        let offset = TimelineInitialBottomAnchor.newestOffsetReplacingTopAnchor(
            requestedY: -20,
            currentY: -20,
            contentHeight: 400,
            viewportHeight: 700,
            topInset: 20,
            bottomInset: 12,
            redirects: true,
            isUserDriven: false
        )
        #expect(offset == nil)
    }

    // Dragging has to be able to reach the oldest photos, and a month jump
    // deliberately asks for the top.
    @Test func leavesTopAnchorAloneWhileDraggingOrWhenRedirectIsOff() {
        let dragging = TimelineInitialBottomAnchor.newestOffsetReplacingTopAnchor(
            requestedY: -100,
            currentY: 400,
            contentHeight: 2000,
            viewportHeight: 700,
            topInset: 100,
            bottomInset: 34,
            redirects: true,
            isUserDriven: true
        )
        let monthJump = TimelineInitialBottomAnchor.newestOffsetReplacingTopAnchor(
            requestedY: -100,
            currentY: 400,
            contentHeight: 2000,
            viewportHeight: 700,
            topInset: 100,
            bottomInset: 34,
            redirects: false,
            isUserDriven: false
        )
        #expect(dragging == nil)
        #expect(monthJump == nil)
    }

    // An ordinary scroll to a month must not be rewritten into a jump to the end.
    @Test func leavesNonTopRequestsAlone() {
        let offset = TimelineInitialBottomAnchor.newestOffsetReplacingTopAnchor(
            requestedY: 500,
            currentY: 100,
            contentHeight: 2000,
            viewportHeight: 700,
            topInset: 100,
            bottomInset: 34,
            redirects: true,
            isUserDriven: false
        )
        #expect(offset == nil)
    }
}
