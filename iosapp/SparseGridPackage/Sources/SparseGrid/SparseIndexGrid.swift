#if os(iOS)
import Combine
import SwiftUI
import UIKit

// Registered once. A generic type cannot store a static constant.
private let sparseIndexCellReuseIdentifier = "SparseIndexCell"

// Tells UIKit where to scroll when the bounds change. Without this the
// collection view keeps the old content offset, and that offset is a
// different photo after the column count changes.
final class TimelineGridLayout: UICollectionViewFlowLayout {
    var centerAnchor: TimelineViewportCenterAnchor?
    private var isResolvingCenterAnchor = false

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let centerAnchor, let collectionView, !isResolvingCenterAnchor else {
            return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
        }
        guard !collectionView.isTracking, !collectionView.isDragging else {
            return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
        }
        isResolvingCenterAnchor = true
        defer { isResolvingCenterAnchor = false }
        // Same row math as the restore. Asking the layout for attributes
        // here can prepare the new column count against the old offset
        // and report the previous photo.
        let width = collectionView.bounds.width
        let windowBounds = collectionView.window?.bounds ?? collectionView.bounds
        let portrait = min(windowBounds.width, windowBounds.height)
        let metrics = TimelineGridMetrics.make(layoutWidth: width, portraitWidth: portrait)
        let row = metrics.row(for: centerAnchor.itemIndex)
        let minY = CGFloat(row) * (metrics.side + TimelineGridMetrics.spacing)
        let inset = collectionView.adjustedContentInset
        let y = TimelineViewportCenterAnchor.contentOffsetY(
            itemMinY: minY,
            itemHeight: metrics.side,
            fractionFromItemTop: centerAnchor.fractionFromItemTop,
            viewportHeight: collectionView.bounds.height,
            contentHeight: collectionViewContentSize.height,
            topInset: inset.top,
            bottomInset: inset.bottom
        )
        return CGPoint(x: proposedContentOffset.x, y: y)
    }
}

// Milestones from the first layout. The app names the Instruments
// signposts, because that API only accepts a static string.
public enum SparseGridMilestone {
    case restoredScroll
    case firstLayout
}

// Index-addressed collection view. It lays rows out and reports which
// indices are on screen. The model decides which pages and which nearby
// indices to load. The app draws each cell and records startup timing.
public struct SparseIndexGrid<Model: SparseGridModel>: UIViewRepresentable {
    private let model: Model
    private let cellClass: UICollectionViewCell.Type
    private let configure: (UICollectionViewCell, Int, String?) -> Void
    private let onWillDisplay: (Int, String?) -> Void
    private let onDidEndDisplaying: (Int, String?) -> Void
    private let onSelect: (String) -> Void
    private let onCreated: () -> Void
    private let onEvent: (SparseGridMilestone) -> Void

    // The app draws the cell. The grid only reports the index and the
    // id currently loaded there, which is nil for a placeholder.
    public init(
        model: Model,
        cellClass: UICollectionViewCell.Type,
        configure: @escaping (UICollectionViewCell, Int, String?) -> Void,
        onWillDisplay: @escaping (Int, String?) -> Void,
        onDidEndDisplaying: @escaping (Int, String?) -> Void,
        onSelect: @escaping (String) -> Void,
        onCreated: @escaping () -> Void,
        onEvent: @escaping (SparseGridMilestone) -> Void = { _ in }
    ) {
        self.model = model
        self.cellClass = cellClass
        self.configure = configure
        self.onWillDisplay = onWillDisplay
        self.onDidEndDisplaying = onDidEndDisplaying
        self.onSelect = onSelect
        self.onCreated = onCreated
        self.onEvent = onEvent
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            configure: configure,
            onWillDisplay: onWillDisplay,
            onDidEndDisplaying: onDidEndDisplaying,
            onSelect: onSelect,
            onEvent: onEvent
        )
    }

    // Creates the UIKit timeline grid and emits the first collection-view creation milestone.
    public func makeUIView(context: Context) -> UICollectionView {
        let layout = TimelineGridLayout()
        layout.minimumLineSpacing = TimelineGridMetrics.spacing
        layout.minimumInteritemSpacing = TimelineGridMetrics.spacing
        layout.sectionInset = .zero
        // The row is measured against the content inset. Horizontal
        // insets stay 0 so that width is the full grid, not the safe area.
        layout.sectionInsetReference = .fromContentInset

        let collectionView = InitialLayoutCollectionView(frame: .zero, collectionViewLayout: layout)
        onCreated()
        collectionView.backgroundColor = .systemBackground
        // Automatic adjustment keeps the vertical safe area, so the first
        // and last rows still clear the bars. The horizontal part is
        // cancelled in the collection view, or landscape gains side margins.
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(cellClass, forCellWithReuseIdentifier: sparseIndexCellReuseIdentifier)
        collectionView.onDidLayoutSubviews = { [weak coordinator = context.coordinator] in
            coordinator?.performInitialScrollIfNeeded()
        }
        collectionView.onBoundsWillPreserveCenter = { [weak coordinator = context.coordinator] in
            coordinator?.freezeCenterAnchorForBoundsChange()
        }
        collectionView.onBoundsWidthWillChange = { [weak coordinator = context.coordinator] preservesCenter in
            coordinator?.handleCollectionWidthWillChange(preservesCenter: preservesCenter)
        }
        collectionView.onBoundsWidthChanged = { [weak coordinator = context.coordinator] preservesCenter in
            coordinator?.handleCollectionWidthChange(preservesCenter: preservesCenter)
        }
        collectionView.onBoundsSettled = { [weak coordinator = context.coordinator] in
            coordinator?.handleBoundsSettled()
        }
        collectionView.onHorizontalContentInsetChanged = { [weak coordinator = context.coordinator] in
            coordinator?.handleHorizontalContentInsetChange()
        }

        context.coordinator.attach(collectionView: collectionView)
        return collectionView
    }

    // Refreshes coordinator references so UIKit callbacks keep using the latest SwiftUI state.
    public func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.updateReferences(
            model: model,
            configure: configure,
            onWillDisplay: onWillDisplay,
            onDidEndDisplaying: onDidEndDisplaying,
            onSelect: onSelect,
            onEvent: onEvent
        )
        context.coordinator.performInitialScrollIfNeeded()
    }

    public final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        private var model: Model
        private var configure: (UICollectionViewCell, Int, String?) -> Void
        private var onWillDisplay: (Int, String?) -> Void
        private var onDidEndDisplaying: (Int, String?) -> Void
        private var onSelect: (String) -> Void
        private var onEvent: (SparseGridMilestone) -> Void
        private weak var collectionView: UICollectionView?
        private var cancellables: Set<AnyCancellable> = []

        fileprivate var hasPerformedInitialScroll = false
        private var hasCommittedInitialPosition = false
        fileprivate var lastKnownTotalCount = 0
        private var lastKnownTopVisibleIndex: Int?
        private var isProgrammaticMonthJumpInFlight = false
        private var lastStableContentOffsetY: CGFloat?
        private var pendingWidthChangeAnchor: (indexPath: IndexPath, offsetFromItemTop: CGFloat)?
        // Set before the collection view lays out a new size, so a scroll
        // callback during that pass cannot replace the anchor with the
        // photo that happens to sit at the old offset.
        private var isHandlingWidthChange = false
        // Stops a layout pass started by the restore itself from running
        // the restore again and clearing the in-progress flag early.
        private var isRestoringBoundsAnchor = false
        private var stableCenterAnchor: TimelineViewportCenterAnchor?
        private var activeRotationAnchor: TimelineViewportCenterAnchor?
        private var isWatchingRotationEnd = false
        private var clearsRotationHoldWhenBoundsSettle = false
        private var stableLayoutsAfterRotation = 0
        private var isFinishingRotation = false
        private var isReapplyingRotationAnchor = false
        private var hasPendingReconfigure = false
        private var hasPendingTotalCountReload = false
        init(
            model: Model,
            configure: @escaping (UICollectionViewCell, Int, String?) -> Void,
            onWillDisplay: @escaping (Int, String?) -> Void,
            onDidEndDisplaying: @escaping (Int, String?) -> Void,
            onSelect: @escaping (String) -> Void,
            onEvent: @escaping (SparseGridMilestone) -> Void
        ) {
            self.model = model
            self.configure = configure
            self.onWillDisplay = onWillDisplay
            self.onDidEndDisplaying = onDidEndDisplaying
            self.onSelect = onSelect
            self.onEvent = onEvent
            self.lastKnownTotalCount = model.totalCount
        }

        func attach(collectionView: UICollectionView) {
            self.collectionView = collectionView
            bindToManager()
        }

        func updateReferences(
            model: Model,
            configure: @escaping (UICollectionViewCell, Int, String?) -> Void,
            onWillDisplay: @escaping (Int, String?) -> Void,
            onDidEndDisplaying: @escaping (Int, String?) -> Void,
            onSelect: @escaping (String) -> Void,
            onEvent: @escaping (SparseGridMilestone) -> Void
        ) {
            self.model = model
            self.configure = configure
            self.onWillDisplay = onWillDisplay
            self.onDidEndDisplaying = onDidEndDisplaying
            self.onSelect = onSelect
            self.onEvent = onEvent
        }

        private func bindToManager() {
            model.revisionPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    if self.model.isGridScrolling || self.isProgrammaticMonthJumpInFlight {
                        self.hasPendingReconfigure = true
                        return
                    }
                    self.reconfigureVisibleCells()
                }
                .store(in: &cancellables)

            model.totalCountPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] updatedCount in
                    guard let self, let collectionView = self.collectionView else { return }
                    guard self.lastKnownTotalCount != updatedCount else { return }
                    if self.shouldHoldGridReload(collectionView) {
                        self.hasPendingTotalCountReload = true
                        return
                    }
                    self.applyTotalCount(updatedCount, in: collectionView)
                }
                .store(in: &cancellables)

            model.scrollTargetIndexPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] targetIndex in
                    guard let self, let targetIndex else { return }
                    self.scrollToTarget(index: targetIndex)
                }
                .store(in: &cancellables)
        }

        /// Reconfigures visible cells so they pick up newly-loaded data.
        private func reconfigureVisibleCells() {
            guard let collectionView else { return }
            let visible = collectionView.indexPathsForVisibleItems
            guard !visible.isEmpty else { return }
            collectionView.reconfigureItems(at: visible)
            performInitialScrollIfNeeded()
        }

        /// Flushes a deferred reconfigure that was suppressed while
        /// the grid was scrolling or a month jump was in flight.
        private func flushPendingReconfigure() {
            guard hasPendingReconfigure else { return }
            hasPendingReconfigure = false
            reconfigureVisibleCells()
        }

        // A count that lands while the finger is down, the grid is
        // coasting, or a month jump is animating would reload the
        // collection view and cancel that scroll.
        private func shouldHoldGridReload(_ collectionView: UICollectionView) -> Bool {
            TimelineLiveUpdatePolicy.shouldHold(
                isTracking: collectionView.isTracking,
                isDragging: collectionView.isDragging,
                isDecelerating: collectionView.isDecelerating,
                isGridScrolling: model.isGridScrolling,
                isProgrammaticJump: isProgrammaticMonthJumpInFlight
            )
        }

        // Rebuilds the grid for a new photo count and keeps the photo
        // that was on screen. The manager's index for that row may
        // already have moved, so the anchor is the cell's item id.
        private func applyTotalCount(_ updatedCount: Int, in collectionView: UICollectionView) {
            guard lastKnownTotalCount != updatedCount else { return }
            lastKnownTotalCount = updatedCount
            let preserved = hasCommittedInitialPosition
                ? preservedVisibleItem(in: collectionView)
                : nil
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            if let preserved,
               let newIndex = model.index(ofItemId: preserved.itemId) {
                let restored = restoreVisibleTopAnchor(
                    (IndexPath(item: newIndex, section: 0), preserved.offsetFromItemTop),
                    in: collectionView
                )
                if restored {
                    collectionView.layoutIfNeeded()
                    model.savedContentOffset = collectionView.contentOffset
                    model.savedViewportAnchorIndex = newIndex
                    model.savedViewportAnchorOffsetFromItemTop = preserved.offsetFromItemTop
                    lastStableContentOffsetY = collectionView.contentOffset.y
                    publishViewportMonth(in: collectionView, force: true)
                }
            }
            performInitialScrollIfNeeded()
        }

        // Applies a photo-count change that arrived during a flick before
        // refreshing visible cells. The reload already rebuilds those cells.
        private func flushPendingGridUpdates() {
            if hasPendingTotalCountReload {
                hasPendingTotalCountReload = false
                hasPendingReconfigure = false
                if let collectionView {
                    applyTotalCount(model.totalCount, in: collectionView)
                }
                return
            }
            flushPendingReconfigure()
        }

        // Restores a previously saved scroll position, or anchors to the newest row on first launch.
        func performInitialScrollIfNeeded() {
            guard !hasPerformedInitialScroll,
                  model.totalCount > 0,
                  let collectionView else { return }
            model.savedGridWidth = collectionView.bounds.width
            let newestItemIndex = model.totalCount - 1
            collectionView.layoutIfNeeded()
            guard collectionView.window != nil else { return }
            guard collectionView.bounds.height > 0 else { return }
            guard collectionView.contentSize.height > 0 else { return }
            guard collectionView.numberOfItems(inSection: 0) > newestItemIndex else { return }
            guard !collectionView.isDragging, !collectionView.isDecelerating else { return }

            if let saved = model.savedContentOffset {
                hasPerformedInitialScroll = true
                var restoredOffset = saved
                if let anchorIndex = model.savedViewportAnchorIndex,
                   let anchorOffset = model.savedViewportAnchorOffsetFromItemTop {
                    let metrics = gridMetrics(for: collectionView)
                    let row = metrics.row(for: anchorIndex)
                    restoredOffset.y = (CGFloat(row) * (metrics.side + TimelineGridMetrics.spacing)) + anchorOffset
                }
                collectionView.setContentOffset(restoredOffset, animated: false)
                collectionView.layoutIfNeeded()
                hasCommittedInitialPosition = true
                (collectionView as? InitialLayoutCollectionView)?.redirectsTopAnchorsToBottom = true
                lastStableContentOffsetY = collectionView.contentOffset.y
                rememberCenterAnchor(in: collectionView)
                publishViewportMonth(in: collectionView, force: true)
                onEvent(.restoredScroll)
                return
            }

            let inset = collectionView.adjustedContentInset
            let targetY = TimelineInitialBottomAnchor.targetYOffset(
                contentHeight: collectionView.contentSize.height,
                viewportHeight: collectionView.bounds.height,
                topInset: inset.top,
                bottomInset: inset.bottom
            )
            let anchoredOffset = CGPoint(x: collectionView.contentOffset.x, y: targetY)
            hasPerformedInitialScroll = true
            if abs(collectionView.contentOffset.y - targetY) > 0.5 {
                collectionView.setContentOffset(anchoredOffset, animated: false)
                collectionView.layoutIfNeeded()
            }
            hasCommittedInitialPosition = true
            (collectionView as? InitialLayoutCollectionView)?.redirectsTopAnchorsToBottom = true
            lastStableContentOffsetY = collectionView.contentOffset.y
            rememberCenterAnchor(in: collectionView)
            publishViewportMonth(in: collectionView, force: true)
            onEvent(.firstLayout)
        }

        // Index 0 publishes a month before the bottom anchor moves the
        // viewport. A width change then lays out only the newest cell for
        // one frame, and the rate limit keeps whichever month arrived
        // first. A committed position publishes the visible top, and a
        // one-cell layout is ignored so that frame cannot stick.
        private func publishViewportMonth(
            in collectionView: UICollectionView,
            force: Bool
        ) {
            let visible = collectionView.indexPathsForVisibleItems.map(\.item)
            if visible.count < 2, model.totalCount > 1 {
                return
            }
            guard let top = topVisibleItemIndex(in: collectionView) else { return }
            if !force, top == lastKnownTopVisibleIndex { return }
            lastKnownTopVisibleIndex = top
            model.updateCurrentMonth(for: top, force: force)
        }

        // Safe-area insets arrive after the bounds width on rotation.
        // Relayout then, or the row keeps the pre-inset cell size and
        // opens the landscape hole between two oversized cells. A
        // rotation already holding the middle photo restores that photo
        // again here instead of pinning the new top row.
        func handleHorizontalContentInsetChange() {
            guard let collectionView else { return }
            guard hasCommittedInitialPosition else {
                collectionView.collectionViewLayout.invalidateLayout()
                return
            }
            // The inset pass can run before the new height is recorded.
            // That pass still belongs to the rotation, so it keeps the
            // middle photo instead of pinning whatever row is now on top.
            let pendingRotation = (collectionView as? InitialLayoutCollectionView)?
                .hasPendingRotationChange ?? false
            let preservesCenter = activeRotationAnchor != nil || pendingRotation
            handleCollectionWidthWillChange(preservesCenter: preservesCenter)
            handleCollectionWidthChange(preservesCenter: preservesCenter)
        }

        // Copies the middle photo before UIKit applies the new bounds.
        // setBounds adjusts the content offset, and the scroll callback
        // would otherwise snapshot whatever photo landed under the center.
        func freezeCenterAnchorForBoundsChange() {
            guard hasCommittedInitialPosition, let collectionView else { return }
            installRotationAnchor(in: collectionView)
        }

        // Captures the anchor before the collection view lays out the new
        // width. Rotation keeps the middle photo already snapshotted while
        // scrolling. A width-only change, such as the month sidebar, keeps
        // the top photo.
        func handleCollectionWidthWillChange(preservesCenter: Bool) {
            guard let collectionView else { return }
            guard hasCommittedInitialPosition else { return }
            isHandlingWidthChange = true
            if preservesCenter || activeRotationAnchor != nil {
                installRotationAnchor(in: collectionView)
                stableLayoutsAfterRotation = 0
                return
            }
            // The top photo was recorded while the columns still matched
            // the screen. Cells here can already be the new column count:
            // the scroll UIKit emits inside setBounds prepares that layout
            // before this callback, and the prepared row is a different photo.
            if let index = model.savedViewportAnchorIndex,
               let offset = model.savedViewportAnchorOffsetFromItemTop {
                pendingWidthChangeAnchor = (IndexPath(item: index, section: 0), offset)
            } else if let top = topAnchorFromVisibleCells(in: collectionView) {
                pendingWidthChangeAnchor = top
            }
        }

        // Invalidates and re-anchors layout when the collection width
        // changes. The month sidebar keeps the top photo. Rotation keeps
        // the held middle photo, including the later safe-area pass.
        func handleCollectionWidthChange(preservesCenter: Bool) {
            guard let collectionView else {
                isHandlingWidthChange = false
                return
            }
            guard hasCommittedInitialPosition else {
                isHandlingWidthChange = false
                return
            }
            guard !isRestoringBoundsAnchor else { return }
            let persistedAnchor: (indexPath: IndexPath, offsetFromItemTop: CGFloat)? = {
                guard let index = model.savedViewportAnchorIndex,
                      let offset = model.savedViewportAnchorOffsetFromItemTop else {
                    return nil
                }
                return (IndexPath(item: index, section: 0), offset)
            }()
            let capturedTopAnchor = pendingWidthChangeAnchor ?? persistedAnchor
            pendingWidthChangeAnchor = nil
            isHandlingWidthChange = true
            isRestoringBoundsAnchor = true
            defer {
                isRestoringBoundsAnchor = false
                isHandlingWidthChange = false
            }
            let useCenter = preservesCenter || activeRotationAnchor != nil
            if useCenter {
                installRotationAnchor(in: collectionView)
            }
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            // A rotation that cannot find the middle photo must not fall
            // through to the top photo. That fallthrough is what jumps
            // the grid when the center snapshot is missing for one frame.
            // The sidebar keeps the photo it pinned. The new column count
            // starts that photo's row on an earlier item, and saving the
            // new row start walks the viewport up when the sidebar closes.
            var pinnedTop: (indexPath: IndexPath, offsetFromItemTop: CGFloat)?
            if useCenter {
                _ = restoreViewportCenterAnchor(activeRotationAnchor, in: collectionView)
            } else {
                let topAnchor = capturedTopAnchor ?? visibleTopAnchor(in: collectionView)
                if restoreVisibleTopAnchor(topAnchor, in: collectionView) {
                    pinnedTop = topAnchor
                } else if let lastStableContentOffsetY {
                    setContentOffsetY(lastStableContentOffsetY, in: collectionView)
                }
            }
            if !useCenter {
                rememberCenterAnchor(in: collectionView)
            }
            model.savedContentOffset = collectionView.contentOffset
            model.savedGridWidth = collectionView.bounds.width
            lastStableContentOffsetY = collectionView.contentOffset.y
            collectionView.layoutIfNeeded()
            if let pinnedTop {
                model.savedViewportAnchorIndex = pinnedTop.indexPath.item
                model.savedViewportAnchorOffsetFromItemTop = pinnedTop.offsetFromItemTop
            } else {
                // Rotation lands on a new top row. Record that row so the
                // next sidebar open pins the photo now on screen.
                rememberSettledTopAnchor(in: collectionView)
            }
            publishViewportMonth(in: collectionView, force: true)
            // The width-change layout pass can finish with only the newest
            // cell in existence. Publish again after that pass so the
            // settled top row replaces it. A pinned sidebar photo stays
            // pinned: re-reading the cells would replace it with the new
            // row start.
            let keepPinnedTop = pinnedTop != nil
            DispatchQueue.main.async { [weak collectionView] in
                guard let collectionView else { return }
                if (collectionView as? InitialLayoutCollectionView)?
                    .hasUncommittedBoundsChange == true {
                    return
                }
                if !keepPinnedTop {
                    self.rememberSettledTopAnchor(in: collectionView)
                }
                self.publishViewportMonth(in: collectionView, force: true)
            }
        }

        // Without a transition coordinator, the first layout that keeps
        // the new size is the end of the resize. Clearing the hold there
        // lets the next gesture capture a fresh middle photo.
        func handleBoundsSettled() {
            guard activeRotationAnchor != nil else { return }
            guard !isHandlingWidthChange, !isRestoringBoundsAnchor else { return }
            guard !isReapplyingRotationAnchor, !isFinishingRotation else { return }
            reapplyRotationAnchor()
            stableLayoutsAfterRotation += 1
            // The first idle layout re-applies the middle photo. The next
            // one releases the hold, after a trailing offset change has
            // had a chance to be corrected.
            guard stableLayoutsAfterRotation >= 2 else { return }
            guard clearsRotationHoldWhenBoundsSettle || !isWatchingRotationEnd else { return }
            finishRotationHold(in: collectionView)
        }

        // Updates persisted offset and active month with a low-cost visible-index lookup suitable for per-frame callbacks.
        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // The resize scroll happens before layout records the new size.
            // Saving here would name a photo from the old offset under the
            // new column count, and the next sidebar open would jump to it.
            if let grid = scrollView as? InitialLayoutCollectionView,
               grid.hasUncommittedBoundsChange {
                return
            }
            let captureSuppressed = (scrollView as? InitialLayoutCollectionView)?
                .suppressesCenterAnchorCapture ?? false
            guard !isHandlingWidthChange, activeRotationAnchor == nil, !captureSuppressed else { return }
            if hasCommittedInitialPosition {
                model.savedContentOffset = scrollView.contentOffset
                lastStableContentOffsetY = scrollView.contentOffset.y
            }
            guard let collectionView = scrollView as? UICollectionView else { return }
            model.savedGridWidth = collectionView.bounds.width
            guard !isProgrammaticMonthJumpInFlight else { return }
            let visibleCount = collectionView.indexPathsForVisibleItems.count
            let layoutSettled = visibleCount >= 2 || model.totalCount <= 1
            // The row comes from the offset and the current column count.
            // Layout attributes during a resize still name the previous
            // photo, and the sidebar would then pin that other row.
            if hasCommittedInitialPosition, layoutSettled {
                rememberSettledTopAnchor(in: collectionView)
            }
            // Snapshot while the layout still matches the screen. A bounds
            // change must not recompute this from the new column count.
            if hasCommittedInitialPosition, layoutSettled {
                rememberCenterAnchor(in: collectionView)
            }
            publishViewportMonth(in: collectionView, force: false)
        }

        // Flags dragging start so sidebar can avoid expensive animation during active grid interaction.
        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if activeRotationAnchor != nil {
                finishRotationHold(in: collectionView)
            }
            isProgrammaticMonthJumpInFlight = false
            (scrollView as? InitialLayoutCollectionView)?.redirectsTopAnchorsToBottom = true
            model.setGridScrolling(true)
        }

        // Clears drag flag when user lifts finger and no deceleration remains.
        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                model.setGridScrolling(false)
                flushPendingGridUpdates()
                if let collectionView = scrollView as? UICollectionView {
                    rememberCenterAnchor(in: collectionView)
                    publishViewportMonth(in: collectionView, force: true)
                }
            }
        }

        // Clears drag flag after inertial scrolling settles so sidebar may resume animated autoscroll.
        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            model.setGridScrolling(false)
            flushPendingGridUpdates()
            if let collectionView = scrollView as? UICollectionView {
                rememberCenterAnchor(in: collectionView)
                publishViewportMonth(in: collectionView, force: true)
            }
        }

        // A notch tap asks for the oldest photos. The timeline is
        // oldest-first, so that is the top inset. Returning false keeps
        // UIKit from scrolling again. Tab reselect does not come through
        // here; it sets the top offset directly and is sent to the newest
        // row. This is not a month jump, so the sidebar follows the
        // viewport when the animation ends.
        public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            let topY = -scrollView.adjustedContentInset.top
            guard abs(scrollView.contentOffset.y - topY) > 0.5 else { return false }
            (scrollView as? InitialLayoutCollectionView)?.honorsNextTopAnchor = true
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: topY),
                animated: true
            )
            return false
        }

        // Ends a programmatic scroll. A month jump keeps the tapped month
        // highlighted: the last month cannot reach the top, and republishing
        // the viewport month would snap the sidebar back to the earlier
        // month still visible there. Hand scrolling clears the flag in
        // scrollViewWillBeginDragging and tracks the viewport again.
        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            let wasMonthJump = isProgrammaticMonthJumpInFlight
            isProgrammaticMonthJumpInFlight = false
            (scrollView as? InitialLayoutCollectionView)?.redirectsTopAnchorsToBottom = true
            model.setGridScrolling(false)
            flushPendingGridUpdates()
            if let collectionView = scrollView as? UICollectionView {
                // The jump blocks per-frame anchor updates. Record the
                // settled middle and top once, or the next sidebar resize
                // restores wherever the grid was before the jump.
                rememberCenterAnchor(in: collectionView)
                rememberSettledTopAnchor(in: collectionView)
                if !wasMonthJump {
                    publishViewportMonth(in: collectionView, force: true)
                }
            }
        }

        // Scrolls as close to the tapped month as the content allows. A
        // jump that cannot move is skipped: UIKit does not call the
        // animation-end callback when the offset is unchanged, and leaving
        // the in-flight flag set would block later viewport month updates.
        private func scrollToTarget(index: Int) {
            guard let collectionView else { return }
            guard index >= 0, index < model.totalCount else {
                isProgrammaticMonthJumpInFlight = false
                model.scrollTargetIndex = nil
                return
            }
            let indexPath = IndexPath(item: index, section: 0)
            guard collectionView.numberOfItems(inSection: 0) > index else {
                isProgrammaticMonthJumpInFlight = false
                model.scrollTargetIndex = nil
                return
            }
            collectionView.layoutIfNeeded()
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                isProgrammaticMonthJumpInFlight = false
                model.scrollTargetIndex = nil
                return
            }
            let inset = collectionView.adjustedContentInset
            let placement = TimelineMonthJumpAnchor.placement(
                itemMinY: attributes.frame.minY,
                currentOffsetY: collectionView.contentOffset.y,
                contentHeight: collectionView.contentSize.height,
                viewportHeight: collectionView.bounds.height,
                topInset: inset.top,
                bottomInset: inset.bottom
            )
            model.scrollTargetIndex = nil
            guard placement.moves else { return }
            isProgrammaticMonthJumpInFlight = true
            // The oldest month sits at the top. That offset is also what a
            // tab reselect asks for, and the grid would otherwise send it
            // to the newest row.
            (collectionView as? InitialLayoutCollectionView)?.redirectsTopAnchorsToBottom = false
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: placement.targetY),
                animated: true
            )
        }

        // The first row the user can see. Cells that only intersect the
        // collection view under the status and navigation bars are still
        // "visible" to UIKit, and taking the lowest index highlights the
        // month peeking out above the bar instead of the top row.
        private func topVisibleItemIndex(in collectionView: UICollectionView) -> Int? {
            let visible = collectionView.indexPathsForVisibleItems
            guard !visible.isEmpty else { return nil }
            let probeY = collectionView.contentOffset.y
                + collectionView.adjustedContentInset.top
                + 8
            var containing: (index: Int, minY: CGFloat)?
            var nearestBelow: (index: Int, minY: CGFloat)?
            for indexPath in visible {
                guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
                    continue
                }
                if frame.minY <= probeY && frame.maxY > probeY {
                    if containing == nil || frame.minY < containing!.minY {
                        containing = (indexPath.item, frame.minY)
                    }
                } else if frame.minY > probeY {
                    if nearestBelow == nil || frame.minY < nearestBelow!.minY {
                        nearestBelow = (indexPath.item, frame.minY)
                    }
                }
            }
            return containing?.index ?? nearestBelow?.index ?? visible.map(\.item).min()
        }

        // The photo at the top of the viewport, read from the cell rather
        // than the manager. Sync updates the manager before this reload, so
        // the cell is the last record of which photo the person was seeing.
        private func preservedVisibleItem(
            in collectionView: UICollectionView
        ) -> (itemId: String, offsetFromItemTop: CGFloat)? {
            guard let anchor = visibleTopAnchor(in: collectionView),
                  let cell = collectionView.cellForItem(at: anchor.indexPath) as? SparseGridCell,
                  let itemId = cell.sparseItemId else {
                return nil
            }
            return (itemId, anchor.offsetFromItemTop)
        }

        // Captures the first visible item and its vertical offset so layout-width changes can preserve the same viewport anchor.
        private func visibleTopAnchor(in collectionView: UICollectionView) -> (indexPath: IndexPath, offsetFromItemTop: CGFloat)? {
            guard let topIndex = topVisibleItemIndex(in: collectionView) else {
                return nil
            }
            let indexPath = IndexPath(item: topIndex, section: 0)
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                return nil
            }
            let delta = collectionView.contentOffset.y - attributes.frame.minY
            return (indexPath, delta)
        }

        // The top row currently on screen, read from the cells rather
        // than from layout attributes. Called before the resize layout
        // so the frames are still the column count the person is seeing.
        private func topAnchorFromVisibleCells(
            in collectionView: UICollectionView
        ) -> (indexPath: IndexPath, offsetFromItemTop: CGFloat)? {
            var topMinY: CGFloat?
            for cell in collectionView.visibleCells {
                if topMinY == nil || cell.frame.minY < topMinY! {
                    topMinY = cell.frame.minY
                }
            }
            guard let topMinY else { return nil }
            var rowStart: (indexPath: IndexPath, minY: CGFloat)?
            for cell in collectionView.visibleCells {
                guard abs(cell.frame.minY - topMinY) < 1,
                      let indexPath = collectionView.indexPath(for: cell) else { continue }
                if rowStart == nil || indexPath.item < rowStart!.indexPath.item {
                    rowStart = (indexPath, cell.frame.minY)
                }
            }
            guard let rowStart else { return nil }
            return (rowStart.indexPath, collectionView.contentOffset.y - rowStart.minY)
        }

        // Records the top row from the column count and the offset, not
        // from layout attributes. Attributes during a resize still
        // describe the previous column count and name the wrong photo.
        private func rememberSettledTopAnchor(in collectionView: UICollectionView) {
            let count = collectionView.numberOfItems(inSection: 0)
            guard count > 0 else { return }
            let metrics = gridMetrics(for: collectionView)
            let pitch = metrics.side + TimelineGridMetrics.spacing
            guard pitch > 0 else { return }
            // Cells are the photo the person is looking at. Use them only
            // when they still sit on the current offset. A bounds change
            // can leave the previous row's frames in place, and those
            // would record a different photo.
            if let top = topAnchorFromVisibleCells(in: collectionView),
               top.offsetFromItemTop > -2,
               top.offsetFromItemTop < pitch {
                model.savedViewportAnchorIndex = top.indexPath.item
                model.savedViewportAnchorOffsetFromItemTop = top.offsetFromItemTop
                return
            }
            // The top edge of the bounds, not a point below the safe area.
            // Adding the inset named the next row and the sidebar pinned that.
            let probeY = collectionView.contentOffset.y + 0.5
            let row = min(max(Int(floor(probeY / pitch)), 0), max((count - 1) / metrics.columns, 0))
            let index = min(row * metrics.columns, count - 1)
            let minY = CGFloat(row) * pitch
            model.savedViewportAnchorIndex = index
            model.savedViewportAnchorOffsetFromItemTop = collectionView.contentOffset.y - minY
        }

        // Records the middle photo while layout still matches the screen,
        // so a later rotation can put that same point back in the center.
        private func rememberCenterAnchor(in collectionView: UICollectionView) {
            guard let anchor = visibleCenterAnchor(in: collectionView) else { return }
            stableCenterAnchor = anchor
        }

        // The photo under the middle of the viewport. Read from the current
        // layout attributes, which are only valid while the size is stable.
        private func visibleCenterAnchor(
            in collectionView: UICollectionView
        ) -> TimelineViewportCenterAnchor? {
            let frames: [(index: Int, frame: CGRect)] = collectionView.indexPathsForVisibleItems.compactMap { indexPath in
                guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
                    return nil
                }
                return (index: indexPath.item, frame: frame)
            }
            let viewportCenter = CGPoint(
                x: collectionView.contentOffset.x + collectionView.bounds.width / 2,
                y: collectionView.contentOffset.y + collectionView.bounds.height / 2
            )
            return TimelineViewportCenterAnchor.capturing(
                itemFrames: frames,
                viewportCenter: viewportCenter
            )
        }

        // Puts the held middle photo's saved point back on the viewport
        // center after the grid reflows into the new column count.
        @discardableResult
        private func restoreViewportCenterAnchor(
            _ anchor: TimelineViewportCenterAnchor?,
            in collectionView: UICollectionView
        ) -> Bool {
            guard let anchor else { return false }
            guard collectionView.numberOfItems(inSection: 0) > anchor.itemIndex else {
                return false
            }
            // Metrics follow the bounds we have now. Layout attributes can
            // still describe the previous column count for a frame, and
            // restoring from those frames lands on a different photo.
            let metrics = gridMetrics(for: collectionView)
            let row = metrics.row(for: anchor.itemIndex)
            let height = metrics.side
            let minY = CGFloat(row) * (metrics.side + TimelineGridMetrics.spacing)
            let inset = collectionView.adjustedContentInset
            let y = TimelineViewportCenterAnchor.contentOffsetY(
                itemMinY: minY,
                itemHeight: height,
                fractionFromItemTop: anchor.fractionFromItemTop,
                viewportHeight: collectionView.bounds.height,
                contentHeight: collectionView.contentSize.height,
                topInset: inset.top,
                bottomInset: inset.bottom
            )
            setContentOffsetY(y, in: collectionView)
            return true
        }

        // Pins the snapshotted middle photo into the layout so UIKit's
        // own bounds-change offset uses it, and so a scroll-to-top during
        // the rotation is not sent to the newest row.
        private func installRotationAnchor(in collectionView: UICollectionView) {
            if activeRotationAnchor == nil {
                activeRotationAnchor = stableCenterAnchor
                if activeRotationAnchor != nil {
                    beginRotationHold(in: collectionView)
                }
            }
            guard let activeRotationAnchor else { return }
            (collectionView.collectionViewLayout as? TimelineGridLayout)?.centerAnchor = activeRotationAnchor
            (collectionView as? InitialLayoutCollectionView)?.suspendsTopRedirect = true
        }

        // Puts the held middle photo back in the center. Called again
        // after the size change because UIKit can replace the offset
        // once layout returns.
        private func reapplyRotationAnchor() {
            guard !isReapplyingRotationAnchor else { return }
            guard let collectionView, let activeRotationAnchor else { return }
            isReapplyingRotationAnchor = true
            defer { isReapplyingRotationAnchor = false }
            _ = restoreViewportCenterAnchor(activeRotationAnchor, in: collectionView)
        }

        // Holds the middle photo until the rotation transition finishes.
        // The animation and its completion both put that photo back,
        // because UIKit can move the offset after the first layout.
        private func beginRotationHold(in collectionView: UICollectionView) {
            guard !isWatchingRotationEnd else { return }
            isWatchingRotationEnd = true
            if let coordinator = transitionCoordinator(for: collectionView) {
                coordinator.animate(alongsideTransition: { [weak self] _ in
                    self?.reapplyRotationAnchor()
                }, completion: { [weak self, weak collectionView] _ in
                    self?.reapplyRotationAnchor()
                    self?.finishRotationHold(in: collectionView)
                })
            } else {
                clearsRotationHoldWhenBoundsSettle = true
            }
        }

        // Drops the rotation hold and records the photo now in the middle,
        // plus the new top photo, so the next rotation or remount matches
        // the screen the person is looking at.
        private func finishRotationHold(in collectionView: UICollectionView?) {
            guard !isFinishingRotation else { return }
            guard activeRotationAnchor != nil || isWatchingRotationEnd else { return }
            isFinishingRotation = true
            defer { isFinishingRotation = false }
            reapplyRotationAnchor()
            isWatchingRotationEnd = false
            clearsRotationHoldWhenBoundsSettle = false
            stableLayoutsAfterRotation = 0
            activeRotationAnchor = nil
            let settledView = collectionView ?? self.collectionView
            guard let settledView else { return }
            (settledView.collectionViewLayout as? TimelineGridLayout)?.centerAnchor = nil
            (settledView as? InitialLayoutCollectionView)?.suspendsTopRedirect = false
            rememberCenterAnchor(in: settledView)
            rememberSettledTopAnchor(in: settledView)
            model.savedContentOffset = settledView.contentOffset
            model.savedGridWidth = settledView.bounds.width
            lastStableContentOffsetY = settledView.contentOffset.y
        }

        // The hosting controller owns the rotation transition. The first
        // controller in the responder chain with an active coordinator is
        // the one whose completion means the new size has settled.
        private func transitionCoordinator(
            for view: UIView
        ) -> UIViewControllerTransitionCoordinator? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController,
                   let coordinator = controller.transitionCoordinator {
                    return coordinator
                }
                responder = current.next
            }
            return nil
        }

        // Restores content offset from one saved anchor so the exact same media row stays in place after relayout.
        @discardableResult
        private func restoreVisibleTopAnchor(_ anchor: (indexPath: IndexPath, offsetFromItemTop: CGFloat)?, in collectionView: UICollectionView) -> Bool {
            guard let anchor else {
                return false
            }
            guard collectionView.numberOfItems(inSection: anchor.indexPath.section) > anchor.indexPath.item else {
                return false
            }
            // Metrics follow the bounds we have now. Layout attributes can
            // still describe the previous column count, and restoring
            // from those frames lands on a different row.
            let metrics = gridMetrics(for: collectionView)
            let row = metrics.row(for: anchor.indexPath.item)
            let desiredY = (CGFloat(row) * (metrics.side + TimelineGridMetrics.spacing))
                + anchor.offsetFromItemTop
            setContentOffsetY(desiredY, in: collectionView)
            return true
        }

        // Clamps one vertical offset to UIKit's scroll range so width-change
        // anchor restoration stays valid. Goes through the grid's restore
        // path so an anchor on the oldest row is not treated as a scroll-to-top.
        private func setContentOffsetY(_ y: CGFloat, in collectionView: UICollectionView) {
            let inset = collectionView.adjustedContentInset
            let minY = -inset.top
            let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
            let clampedY = min(max(y, minY), maxY)
            let offset = CGPoint(x: collectionView.contentOffset.x, y: clampedY)
            if let grid = collectionView as? InitialLayoutCollectionView {
                grid.restoreContentOffset(offset)
            } else {
                collectionView.setContentOffset(offset, animated: false)
            }
        }

        public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            model.totalCount
        }

        // Binds one cell to the id loaded at this index. A missing id is
        // a placeholder, and it asks the model for the page that covers it.
        public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: sparseIndexCellReuseIdentifier,
                for: indexPath
            )
            let index = indexPath.item
            let itemId = model.itemId(at: index)
            configure(cell, index, itemId)
            if itemId == nil {
                model.schedulePaging(around: index)
            }
            return cell
        }

        // The cell is about to appear. The app records the id for startup
        // timing; the model warms the rows around it and extends the page.
        public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            let index = indexPath.item
            onWillDisplay(index, model.itemId(at: index))
            model.itemDidAppear(at: index)
            model.schedulePaging(around: index)
        }

        // The cell left the screen. The app drops its startup tracking,
        // and the model drops the index from the visible set.
        public func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            onDidEndDisplaying(indexPath.item, (cell as? SparseGridCell)?.sparseItemId)
            model.itemDidDisappear(at: indexPath.item)
        }

        // UIKit selects the cell before this runs. The photo on the cell
        // can disagree with the loaded-window index, and a state write
        // in this callback can be dropped while that selection sticks, so
        // the next tap never arrives. Clear the selection, and publish the
        // id the cell is showing only once the model can still resolve it.
        public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            let cell = collectionView.cellForItem(at: indexPath) as? SparseGridCell
            let itemId = cell?.sparseItemId ?? model.itemId(at: indexPath.item)
            collectionView.deselectItem(at: indexPath, animated: false)
            guard let itemId, model.index(ofItemId: itemId) != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onSelect(itemId)
            }
        }

        // Sizes every thumbnail so the row fills the grid width. A wider
        // row grows the cells slightly instead of leaving side margins.
        public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            let side = gridMetrics(for: collectionView).side
            return CGSize(width: side, height: side)
        }

        // The row is the collection view's full width, including the
        // area beside the landscape safe area. The month sidebar, when
        // open, is already outside these bounds.
        private func gridMetrics(for collectionView: UICollectionView) -> TimelineGridMetrics {
            let reference = collectionView.window?.bounds ?? collectionView.bounds
            return TimelineGridMetrics.make(
                layoutWidth: collectionView.bounds.width,
                portraitWidth: min(reference.width, reference.height)
            )
        }
    }
}

final class InitialLayoutCollectionView: UICollectionView {
    var onDidLayoutSubviews: (() -> Void)?
    var onBoundsWillPreserveCenter: (() -> Void)?
    var onBoundsWidthWillChange: ((Bool) -> Void)?
    var onBoundsWidthChanged: ((Bool) -> Void)?
    var onBoundsSettled: (() -> Void)?
    // Stays off until the grid has anchored, so the first layout can still
    // place the newest row itself. Month jumps turn it off again so the
    // oldest month can land at the top. A finger drag reaches the top
    // through the tracking path, which is not redirected.
    var redirectsTopAnchorsToBottom = false
    // While a rotation is putting the middle photo back, a system
    // scroll-to-top would otherwise send the grid to the newest row.
    var suspendsTopRedirect = false
    // A notch tap asks for the oldest photos, which sit at the same
    // offset a tab reselect uses. The next offset write is that request
    // and must not be rewritten to the newest row. Cleared after one
    // write so the tab still jumps to the newest photos.
    var honorsNextTopAnchor = false
    // Set for the duration of a bounds change that keeps the middle
    // photo. UIKit scrolls inside that change, and the scroll callback
    // would otherwise replace the snapshot with the jumped photo.
    var suppressesCenterAnchorCapture = false
    var onHorizontalContentInsetChanged: (() -> Void)?
    private var lastKnownBoundsWidth: CGFloat = 0
    private var lastKnownBoundsHeight: CGFloat = 0
    private var lastKnownHorizontalContentInset: CGFloat = -1
    private var isSettingBounds = false

    // The safe-area pass can run before layout records the new size.
    // Callers use this to keep the middle photo during that pass.
    var hasPendingRotationChange: Bool {
        TimelineViewportCenterAnchor.preservesCenter(
            widthDelta: abs(bounds.width - lastKnownBoundsWidth),
            heightDelta: abs(bounds.height - lastKnownBoundsHeight)
        )
    }

    // setBounds updates the size and then scrolls before layoutSubviews.
    // That scroll still sees the previous row geometry. Recording an
    // anchor from it, or asking the layout for attributes, pins the
    // sidebar to a different photo once the new column count is applied.
    var hasUncommittedBoundsChange: Bool {
        guard lastKnownBoundsWidth > 0 else { return false }
        if abs(bounds.width - lastKnownBoundsWidth) > 0.5 { return true }
        if abs(bounds.height - lastKnownBoundsHeight) > 1 { return true }
        return false
    }

    // A horizontal inset shrinks the row the flow layout places into.
    // That is the landscape margin, so a late change has to rebuild
    // the row. Edge-to-edge insets keep this at zero.
    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        let horizontal = adjustedContentInset.left + adjustedContentInset.right
        guard abs(horizontal - lastKnownHorizontalContentInset) > 0.5 else { return }
        lastKnownHorizontalContentInset = horizontal
        onHorizontalContentInsetChanged?()
    }

    // Thumbnails run to the left and right edges. The system still adds
    // the top and bottom safe area, so the first and last rows clear the
    // navigation bar and the tab bar. A negative horizontal content
    // inset cancels that same adjustment on the sides.
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        applyEdgeToEdgeInsets()
    }

    // Cancels the horizontal safe area without touching the vertical
    // insets the scroll view uses to clear the bars. Called from layout
    // as well, because the first pass can happen before
    // safeAreaInsetsDidChange.
    private func applyEdgeToEdgeInsets() {
        let next = UIEdgeInsets(
            top: 0,
            left: -safeAreaInsets.left,
            bottom: 0,
            right: -safeAreaInsets.right
        )
        guard contentInset != next else { return }
        contentInset = next
    }

    // Restoring a saved anchor is not a scroll-to-top gesture, even when the
    // anchor is the oldest row sitting at the top offset.
    func restoreContentOffset(_ offset: CGPoint) {
        super.setContentOffset(offset, animated: false)
    }

    // A tab reselect scrolls to the top. The oldest photos are there, so
    // the request is carried to the newest row instead. A notch tap sets
    // honorsNextTopAnchor so that one write stays at the top.
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        let honorTop = consumeHonoredTopAnchor()
        if suspendsTopRedirect || honorTop {
            super.setContentOffset(contentOffset, animated: animated)
            return
        }
        if let redirected = newestOffset(replacingTopAnchor: contentOffset) {
            super.setContentOffset(redirected, animated: true)
            return
        }
        super.setContentOffset(contentOffset, animated: animated)
    }

    // Some system scroll-to-top paths reveal the zero rect instead of
    // setting an offset. That is the same request as a jump to the top.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        if suspendsTopRedirect {
            super.scrollRectToVisible(rect, animated: animated)
            return
        }
        let top = CGPoint(x: contentOffset.x, y: rect.minY - adjustedContentInset.top)
        if rect.minY <= 1, let redirected = newestOffset(replacingTopAnchor: top) {
            super.setContentOffset(redirected, animated: true)
            return
        }
        super.scrollRectToVisible(rect, animated: animated)
    }

    // A notch tap is allowed through once. Consuming the flag here keeps
    // the next tab reselect, which uses the same top offset, on the
    // newest row.
    private func consumeHonoredTopAnchor() -> Bool {
        guard honorsNextTopAnchor else { return false }
        honorsNextTopAnchor = false
        return true
    }

    // A tab reselect jumps to the top in one write. Dragging and
    // deceleration move the same distance in small steps, and those
    // have to be able to reach the oldest photos. A notch tap is
    // excluded before this runs.
    private func newestOffset(replacingTopAnchor contentOffset: CGPoint) -> CGPoint? {
        let inset = adjustedContentInset
        guard let y = TimelineInitialBottomAnchor.newestOffsetReplacingTopAnchor(
            requestedY: contentOffset.y,
            currentY: self.contentOffset.y,
            contentHeight: contentSize.height,
            viewportHeight: bounds.height,
            topInset: inset.top,
            bottomInset: inset.bottom,
            redirects: redirectsTopAnchorsToBottom,
            isUserDriven: isTracking || isDragging || isDecelerating
        ) else { return nil }
        return CGPoint(x: contentOffset.x, y: y)
    }

    // Freezes the middle photo before UIKit's bounds setter moves the
    // content offset. A willSet observer on this ObjC property is not
    // called when UIKit resizes the view, so the setter itself has to
    // snapshot first. layoutSubviews runs too late: the scroll callback
    // has already replaced the snapshot with the jumped photo.
    override var bounds: CGRect {
        get { super.bounds }
        set {
            if isSettingBounds {
                super.bounds = newValue
                return
            }
            isSettingBounds = true
            defer { isSettingBounds = false }
            let widthDelta = abs(newValue.width - bounds.width)
            let heightDelta = abs(newValue.height - bounds.height)
            let preservesCenter = TimelineViewportCenterAnchor.preservesCenter(
                widthDelta: widthDelta,
                heightDelta: heightDelta
            )
            if preservesCenter {
                suppressesCenterAnchorCapture = true
                onBoundsWillPreserveCenter?()
            }
            super.bounds = newValue
            if preservesCenter {
                suppressesCenterAnchorCapture = false
            }
        }
    }

    // Emits width changes so the grid can keep the same photos. Rotation
    // keeps the middle photo. The month sidebar keeps the top photo.
    override func layoutSubviews() {
        applyEdgeToEdgeInsets()
        let widthDelta = abs(bounds.width - lastKnownBoundsWidth)
        let heightDelta = abs(bounds.height - lastKnownBoundsHeight)
        let widthChanged = widthDelta > 0.5
        let heightChanged = heightDelta > 1
        let preservesCenter = TimelineViewportCenterAnchor.preservesCenter(
            widthDelta: widthDelta,
            heightDelta: heightDelta
        )
        if preservesCenter || widthChanged {
            onBoundsWidthWillChange?(preservesCenter)
        }
        super.layoutSubviews()
        if preservesCenter || widthChanged {
            if widthChanged {
                lastKnownBoundsWidth = bounds.width
            }
            onBoundsWidthChanged?(preservesCenter)
        }
        if widthChanged || heightChanged {
            lastKnownBoundsHeight = bounds.height
        }
        if !widthChanged && !heightChanged {
            onBoundsSettled?()
        }
        onDidLayoutSubviews?()
    }
}
#endif
