import Foundation
import Testing
import UIKit
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

    // A saved anchor on the oldest row uses the top offset, the same place a
    // tab reselect asks for. Restoring that anchor has to stay put, or hiding
    // the month sidebar jumps the timeline to the newest photos.
    @Test @MainActor func restoreContentOffsetKeepsTheOldestRow() {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 140, height: 140)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        let frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let grid = InitialLayoutCollectionView(frame: frame, collectionViewLayout: layout)
        let source = OldestRowGridSource(count: 30)
        grid.dataSource = source
        grid.register(UICollectionViewCell.self, forCellWithReuseIdentifier: OldestRowGridSource.reuseID)
        grid.contentInsetAdjustmentBehavior = .never
        grid.redirectsTopAnchorsToBottom = true
        let window = UIWindow(frame: frame)
        window.addSubview(grid)
        window.makeKeyAndVisible()
        grid.layoutIfNeeded()

        #expect(grid.contentSize.height > grid.bounds.height)
        let top = -grid.adjustedContentInset.top
        grid.restoreContentOffset(CGPoint(x: 0, y: top))
        // A mistaken redirect animates toward the newest row. Spin so that
        // jump shows up as a settled offset instead of a pending animation.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        #expect(
            abs(grid.contentOffset.y - top) <= 0.5,
            "offset \(grid.contentOffset.y) top \(top) size \(grid.contentSize)"
        )
    }
}

// Supplies a fixed number of empty cells so a grid can be laid out tall
// enough to scroll without a timeline manager.
private final class OldestRowGridSource: NSObject, UICollectionViewDataSource {
    static let reuseID = "cell"
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseID, for: indexPath)
    }
}
