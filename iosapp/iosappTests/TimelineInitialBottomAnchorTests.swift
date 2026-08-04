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
}
