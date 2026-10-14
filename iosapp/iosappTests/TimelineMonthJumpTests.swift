import Foundation
import Testing
@testable import iosapp

// Verifies a month tap scrolls as far as the grid allows and reports
// when that position is already showing, so the sidebar can keep the
// tapped month highlighted instead of snapping back to whatever row
// happens to sit at the top.
struct TimelineMonthJumpTests {
    // A month with room above and below lands on its own row.
    @Test func targetsTheTappedRowWhenItFits() {
        let placement = TimelineMonthJumpAnchor.placement(
            itemMinY: 400,
            currentOffsetY: 0,
            contentHeight: 2000,
            viewportHeight: 800,
            topInset: 100,
            bottomInset: 80
        )
        #expect(placement.targetY == 300)
        #expect(placement.moves)
    }

    // The last month cannot reach the top, so the jump stops at the
    // bottom of the content instead of requesting an offset UIKit
    // will ignore.
    @Test func clampsTheLastMonthToTheMaximumOffset() {
        let placement = TimelineMonthJumpAnchor.placement(
            itemMinY: 1800,
            currentOffsetY: 0,
            contentHeight: 2000,
            viewportHeight: 800,
            topInset: 100,
            bottomInset: 80
        )
        #expect(placement.targetY == 1280)
        #expect(placement.moves)
    }

    // An animated scroll that does not move never calls its completion,
    // so the caller has to know to skip it.
    @Test func reportsNoMovementWhenAlreadyAtTheClampedOffset() {
        let placement = TimelineMonthJumpAnchor.placement(
            itemMinY: 1800,
            currentOffsetY: 1280,
            contentHeight: 2000,
            viewportHeight: 800,
            topInset: 100,
            bottomInset: 80
        )
        #expect(placement.targetY == 1280)
        #expect(!placement.moves)
    }
}
