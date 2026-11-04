import CoreGraphics
import Foundation

// Computes the initial timeline grid offset so startup can land on the newest row without a visible jump.
struct TimelineInitialBottomAnchor {
    // Clamps the initial vertical content offset to UIKit's valid scroll range.
    static func targetYOffset(contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let minOffset = -topInset
        let maxOffset = max(minOffset, contentHeight - viewportHeight + bottomInset)
        return maxOffset
    }

    // A tab reselect asks for the top. The oldest photos are there, so
    // the request is carried to the newest row. A notch tap uses the
    // same offset and is let through before this runs. Nil means the
    // original request should stand: the person is dragging, a month
    // jump asked for this offset, or the content is too short to scroll.
    static func newestOffsetReplacingTopAnchor(
        requestedY: CGFloat,
        currentY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        redirects: Bool,
        isUserDriven: Bool
    ) -> CGFloat? {
        guard redirects, !isUserDriven else { return nil }
        let minY = -topInset
        guard requestedY <= minY + 0.5 else { return nil }
        let targetY = targetYOffset(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        // Already on the newest row: stay there so the request cannot
        // continue on to the oldest row.
        let y = abs(currentY - targetY) > 0.5 ? targetY : currentY
        guard y > minY + 0.5 else { return nil }
        return y
    }
}

// Decides how far a month tap can scroll. The last rows cannot reach
// the top of the viewport, and an animated scroll that does not move
// never reports completion, so the caller has to skip it.
struct TimelineMonthJumpAnchor {
    struct Placement: Equatable {
        let targetY: CGFloat
        let moves: Bool
    }

    // Half a point matches the initial-scroll "already there" check so
    // layout rounding does not start a no-op animation.
    private static let movementThreshold: CGFloat = 0.5

    // Puts the tapped item at the top of the viewport, clamped to the
    // range UIKit will actually scroll.
    static func placement(
        itemMinY: CGFloat,
        currentOffsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> Placement {
        let minOffset = -topInset
        let maxOffset = max(minOffset, contentHeight - viewportHeight + bottomInset)
        let desired = itemMinY - topInset
        let targetY = min(max(desired, minOffset), maxOffset)
        return Placement(
            targetY: targetY,
            moves: abs(currentOffsetY - targetY) > movementThreshold
        )
    }
}

// The photo under the middle of the screen stays there when the grid
// reflows. The fraction is the point within that photo the viewport
// center sits on, so a shorter landscape viewport does not jump to
// the old top row. The month sidebar is a small width-only change and
// keeps the top photo instead.
struct TimelineViewportCenterAnchor: Equatable {
    let itemIndex: Int
    let fractionFromItemTop: CGFloat

    // Picks the photo the viewport center sits on. A center that falls
    // in the gap between cells uses the nearest photo, so the rotation
    // hold is not dropped for the 1pt spacing.
    static func capturing(
        itemFrames: [(index: Int, frame: CGRect)],
        viewportCenter: CGPoint
    ) -> TimelineViewportCenterAnchor? {
        let containing = itemFrames.filter { $0.frame.contains(viewportCenter) }
        // The 1pt row gap is close enough to keep the hold. A center that
        // is nowhere near the laid-out cells is a mid-rotation mismatch,
        // and snapping to the nearest photo is what walks the timeline.
        let candidates = containing.isEmpty
            ? itemFrames.filter { distanceOutside($0.frame, viewportCenter) <= 2 }
            : containing
        guard let chosen = candidates.min(by: { lhs, rhs in
            let left = centerDistanceSquared(lhs.frame, viewportCenter)
            let right = centerDistanceSquared(rhs.frame, viewportCenter)
            if left == right {
                return lhs.index < rhs.index
            }
            return left < right
        }) else {
            return nil
        }
        let height = max(chosen.frame.height, 1)
        // A gap pick sits just outside the cell. Keep the fraction on
        // the photo so the restore still targets that photo's edge.
        let raw = (viewportCenter.y - chosen.frame.minY) / height
        let fraction = min(max(raw, 0), 1)
        return TimelineViewportCenterAnchor(
            itemIndex: chosen.index,
            fractionFromItemTop: fraction
        )
    }

    // Content offset that puts the saved point of the anchor photo back
    // on the vertical center. The first and last rows stop at the scroll
    // range instead of moving past the content.
    static func contentOffsetY(
        itemMinY: CGFloat,
        itemHeight: CGFloat,
        fractionFromItemTop: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        let centerY = itemMinY + fractionFromItemTop * itemHeight
        let desired = centerY - viewportHeight / 2
        let minOffset = -topInset
        let maxOffset = max(minOffset, contentHeight - viewportHeight + bottomInset)
        return min(max(desired, minOffset), maxOffset)
    }

    // The month sidebar narrows the grid by 64pt and does not change
    // height. In landscape it also gives back the side safe area, so
    // the width change can pass 100pt, and that resize still keeps the
    // top photo. A jump of a couple hundred points, a real height
    // change, or a change on both axes is a rotation and keeps the
    // middle photo. Height is included on its own because the first
    // rotation frame can arrive before the width does, and capturing
    // after that frame would lock onto the wrong photo.
    static func preservesCenter(widthDelta: CGFloat, heightDelta: CGFloat) -> Bool {
        if widthDelta > 200 { return true }
        if heightDelta > 8 { return true }
        return widthDelta > 0.5 && heightDelta > 1
    }

    // How far the point sits outside the cell. Zero when it is inside.
    // Chebyshev distance matches the row gap without a square root.
    private static func distanceOutside(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(frame.minX - point.x, point.x - frame.maxX, 0)
        let dy = max(frame.minY - point.y, point.y - frame.maxY, 0)
        return max(dx, dy)
    }

    // Squared distance is enough to compare cells, and it avoids a root
    // on a path that can run while the grid is scrolling.
    private static func centerDistanceSquared(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = frame.midX - point.x
        let dy = frame.midY - point.y
        return dx * dx + dy * dy
    }
}

// Chooses how many timeline thumbnails fit across the grid so a row
// fills the width it is given. Widths at or below the portrait width
// stay on three columns, which is what lets the month sidebar shrink
// cells instead of dropping one. Wider rows keep only as many
// portrait-sized cells as fit, then grow them to the edges.
struct TimelineGridMetrics: Equatable {
    static let spacing: CGFloat = 1

    let columns: Int
    let side: CGFloat

    // The side is the exact share of the width, not a floored value.
    // Flooring left a gap at the edge. Growing absorbs the leftover
    // width so the row meets both sides.
    static func make(
        layoutWidth: CGFloat,
        portraitWidth: CGFloat
    ) -> TimelineGridMetrics {
        let width = max(layoutWidth, 1)
        let portrait = max(portraitWidth, 1)
        let columns = columnCount(layoutWidth: width, portraitWidth: portrait)
        let gaps = spacing * CGFloat(columns - 1)
        let side = max((width - gaps) / CGFloat(columns), 1)
        return TimelineGridMetrics(columns: columns, side: side)
    }

    // Estimates the row for one item when the collection view has not
    // produced layout attributes yet, so scroll restoration still lands
    // on the same photo after the column count changes.
    func row(for item: Int) -> Int {
        item / max(columns, 1)
    }

    private static let portraitColumns = 3

    // Portrait and anything narrower (the month sidebar) keep three
    // columns. A wider width keeps only as many portrait-sized cells
    // as fit. The caller then grows those cells to fill the width,
    // instead of adding a column that would shrink them.
    private static func columnCount(layoutWidth: CGFloat, portraitWidth: CGFloat) -> Int {
        if layoutWidth <= portraitWidth + 0.5 {
            return portraitColumns
        }
        let target = (portraitWidth - spacing * CGFloat(portraitColumns - 1)) / CGFloat(portraitColumns)
        let raw = (layoutWidth + spacing) / (max(target, 1) + spacing)
        return max(portraitColumns, Int(raw))
    }
}

// A reload while UIKit is still decelerating cancels the flick. Structural
// timeline updates wait until the finger, the coast, or a month-jump
// animation has finished.
enum TimelineLiveUpdatePolicy {
    // True while a gesture or a month jump still owns the scroll view.
    // A reload in that window cancels the coast.
    static func shouldHold(
        isTracking: Bool,
        isDragging: Bool,
        isDecelerating: Bool,
        isGridScrolling: Bool,
        isProgrammaticJump: Bool
    ) -> Bool {
        isTracking || isDragging || isDecelerating || isGridScrolling || isProgrammaticJump
    }
}
