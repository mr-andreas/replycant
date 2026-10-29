import Foundation
import Testing
@testable import iosapp

// Locks the timeline cell size so a row fills the width it is given.
// Landscape used to stop at the side safe area, and flooring the cell
// left a gap. Extra width now grows the cells instead.
struct TimelineGridMetricsTests {
    // Portrait already looks right: three columns filling the width.
    @Test func keepsPortraitAtThreeColumns() {
        let metrics = TimelineGridMetrics.make(layoutWidth: 440, portraitWidth: 440)
        #expect(metrics.columns == 3)
        #expect(metrics.side == CGFloat(440 - 2) / 3)
        #expect(rowWidth(metrics) == 440)
    }

    // A landscape phone is wider than its short side. Only as many
    // portrait-sized cells as fit are kept, then each grows so the row
    // meets both edges instead of leaving the side margins empty.
    @Test func landscapeGrowsCellsToFillTheWidth() {
        let portrait = TimelineGridMetrics.make(layoutWidth: 440, portraitWidth: 440)
        let landscape = TimelineGridMetrics.make(layoutWidth: 956, portraitWidth: 440)
        #expect(landscape.columns == 6)
        #expect(landscape.side == CGFloat(956 - 5) / 6)
        #expect(landscape.side > portrait.side)
        #expect(rowWidth(landscape) == 956)
    }

    // The month sidebar narrows the grid without changing orientation.
    // Cells shrink to fill that narrower width, still in three columns.
    @Test func narrowerThanPortraitKeepsThreeColumns() {
        let metrics = TimelineGridMetrics.make(layoutWidth: 360, portraitWidth: 440)
        #expect(metrics.columns == 3)
        #expect(metrics.side == CGFloat(360 - 2) / 3)
        #expect(metrics.side < CGFloat(440 - 2) / 3)
        #expect(rowWidth(metrics) == 360)
    }

    // Scroll restoration estimates a row when layout attributes are
    // missing. That estimate has to follow the column count, or a
    // rotation restores the anchor on the wrong row.
    @Test func rowFollowsColumnCount() {
        let landscape = TimelineGridMetrics.make(layoutWidth: 956, portraitWidth: 440)
        #expect(landscape.row(for: landscape.columns - 1) == 0)
        #expect(landscape.row(for: landscape.columns) == 1)

        let portrait = TimelineGridMetrics.make(layoutWidth: 440, portraitWidth: 440)
        #expect(portrait.row(for: 2) == 0)
        #expect(portrait.row(for: 3) == 1)
    }

    // Cells plus the 1pt gaps. This is the width the row must cover.
    private func rowWidth(_ metrics: TimelineGridMetrics) -> CGFloat {
        CGFloat(metrics.columns) * metrics.side
            + CGFloat(metrics.columns - 1) * TimelineGridMetrics.spacing
    }
}
