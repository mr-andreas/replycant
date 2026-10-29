import SwiftUI
import LibGit2
import GitDB
import AVKit
import UIKit
import Combine
import UniformTypeIdentifiers

private struct SelectedTimelineItem: Identifiable {
    let id: String
}

// Computes the initial timeline grid offset so startup can land on the newest row without a visible jump.
struct TimelineInitialBottomAnchor {
    // Clamps the initial vertical content offset to UIKit's valid scroll range.
    static func targetYOffset(contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let minOffset = -topInset
        let maxOffset = max(minOffset, contentHeight - viewportHeight + bottomInset)
        return maxOffset
    }

    // A tab reselect or status-bar tap asks for the top. The oldest photos
    // are there, so the request is carried to the newest row. Nil means the
    // original request should stand: the person is dragging, a month jump
    // asked for this offset, or the content is too short to scroll.
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

// Renders the photo timeline grid while requesting sparse pages as cells come into view.
struct TimelineView: View {
    // Defines deterministic preview modes so canvas rendering never depends on repository setup.
    enum PreviewState {
        case loading
        case error(String)
        case empty
    }

    @StateObject private var timelineManager: TimelineManager
    @ObservedObject private var uploadController = UploadController.shared
    @ObservedObject private var syncManager = PhotoSyncManager.shared
    @ObservedObject private var uploadBacklog = UploadBacklogTracker.shared
    @State private var showUploadDetails = false
    private let previewState: PreviewState?
    private let previewShowsEnableBanner: Bool

    // Allows previews to render TimelineView states without repository and LFS dependencies.
    // previewShowsEnableBanner forces the offer over an empty preview, which
    // is the only way the gallery can show it without a loaded library.
    init(previewState: PreviewState? = nil, previewShowsEnableBanner: Bool = false) {
        self.previewState = previewState
        self.previewShowsEnableBanner = previewShowsEnableBanner
        _timelineManager = StateObject(wrappedValue: TimelineManager())
    }

    // Canvas skips app launch setup, so a real load would reach an
    // uninitialized libgit2 and take the whole preview down with it.
    static func shouldLoadTimeline(
        previewState: PreviewState?,
        isRunningForPreviews: Bool
    ) -> Bool {
        previewState == nil && !isRunningForPreviews
    }

    var body: some View {
        // NavigationStack keeps timeline content in the primary column on iPad;
        // NavigationView would park it in a collapsed sidebar with an empty detail pane.
        NavigationStack {
            TimelineGridScreen(
                timelineManager: timelineManager,
                previewState: previewState,
                emptyTitle: "No photos uploaded yet",
                emptyMessage: "Upload some photos to see them in your timeline",
                emptyAction: emptyUploadAction,
                onInitialLoad: {
                    Task { await uploadController.launchDidFinish() }
                }
            )
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if UploadDetailsCopy.activityIndicator(for: syncManager.syncState) != .hidden {
                    ToolbarItem(placement: .topBarLeading) {
                        UploadProgressButton(state: syncManager.syncState) {
                            showUploadDetails = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showUploadDetails) {
                UploadDetailsView(
                    syncManager: syncManager,
                    isOverdue: uploadBacklog.isOverdue,
                    onRetry: {
                        Task { await uploadController.startIfReady() }
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            if showsEnableBanner {
                UploadEnableBanner(
                    onEnable: { Task { await uploadController.enable() } },
                    onDismiss: { uploadController.dismissPrompt() }
                )
                .padding(.top, 44)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: showsEnableBanner)
    }

    // The banner is for a timeline that already has photos. The empty
    // screen keeps its button even after the banner was dismissed.
    private var showsEnableBanner: Bool {
        if previewShowsEnableBanner { return true }
        guard previewState == nil else { return false }
        return UploadController.showsEnableBanner(
            isEnabled: uploadController.isEnabled,
            isDismissed: uploadController.isPromptDismissed,
            isTimelineEmpty: timelineManager.isLoading || timelineManager.totalCount == 0
        )
    }

    // Shown whenever upload is off, including after the banner was
    // dismissed. The banner preview hides it so that tile is only the bar.
    private var emptyUploadAction: TimelineEmptyAction? {
        let show: Bool
        switch previewState {
        case .empty:
            show = !previewShowsEnableBanner
        case nil:
            show = !uploadController.isEnabled
        default:
            show = false
        }
        guard show else { return nil }
        return TimelineEmptyAction(
            title: "Enable upload",
            accessibilityIdentifier: "enableUploadButton",
            perform: { Task { await uploadController.enable() } }
        )
    }
}

// The empty timeline's upload button. Places passes none, because that
// grid is a filter over photos that are already in the library.
struct TimelineEmptyAction {
    var title: String
    var accessibilityIdentifier: String
    var perform: () -> Void
}

// The timeline grid, including its viewer and month sidebar, so a place
// can show the same browsing flow for one cluster's photos.
struct TimelineGridScreen: View {
    @ObservedObject var timelineManager: TimelineManager
    var previewState: TimelineView.PreviewState? = nil
    var emptyTitle: String
    var emptyMessage: String
    var emptyAction: TimelineEmptyAction? = nil
    var onInitialLoad: (() -> Void)? = nil
    @State private var selectedItem: SelectedTimelineItem?
    @State private var showMonthSidebar = false

    var body: some View {
        VStack {
            if timelineManager.isLoading {
                loadingView
            } else if let error = timelineManager.errorMessage {
                errorView(error)
            } else if timelineManager.totalCount == 0 {
                emptyView
            } else {
                timelineList
            }
        }
        .fullScreenCover(item: $selectedItem) { selected in
            FullScreenMediaView(initialItemId: selected.id, timelineManager: timelineManager)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMonthSidebar.toggle()
                } label: {
                    Image(systemName: showMonthSidebar ? "calendar.badge.minus" : "calendar")
                }
                .accessibilityIdentifier("toggleTimelineMonthSidebarButton")
                .accessibilityLabel(showMonthSidebar ? "Hide timeline month sidebar" : "Show timeline month sidebar")
            }
        }
        .onAppear {
            guard let previewState else { return }
            switch previewState {
            case .loading:
                timelineManager.errorMessage = nil
                timelineManager.isLoading = true
            case .error(let message):
                timelineManager.isLoading = false
                timelineManager.errorMessage = message
            case .empty:
                timelineManager.isLoading = false
                timelineManager.errorMessage = nil
            }
        }
        .refreshable {
            guard TimelineView.shouldLoadTimeline(
                previewState: previewState,
                isRunningForPreviews: ContentView.isRunningForPreviews(
                    environment: ProcessInfo.processInfo.environment
                )
            ) else { return }
            TimelineRenderMilestoneTracker.shared.resetForNewTimelineLoad()
            await timelineManager.loadTimeline(force: true)
        }
        .task {
            guard TimelineView.shouldLoadTimeline(
                previewState: previewState,
                isRunningForPreviews: ContentView.isRunningForPreviews(
                    environment: ProcessInfo.processInfo.environment
                )
            ) else { return }
            TimelineRenderMilestoneTracker.shared.resetForNewTimelineLoad()
            await timelineManager.loadTimeline()
            guard !Task.isCancelled else { return }
            onInitialLoad?()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Loading timeline...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            AppSignposts.event("TimelineLoadingVisible")
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Failed to load timeline")
                .font(.headline)

            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task {
                    await timelineManager.loadTimeline()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text(emptyTitle)
                .font(.headline)
                .foregroundColor(.secondary)

            Text(emptyMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let emptyAction {
                Button(emptyAction.title, action: emptyAction.perform)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(emptyAction.accessibilityIdentifier)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Presents a sparse UICollectionView-backed grid so 80k timeline items remain randomly seekable.
    private var timelineList: some View {
        HStack(spacing: 0) {
            TimelineCollectionView(
                timelineManager: timelineManager,
                selectedItemId: Binding(
                    get: { selectedItem?.id },
                    set: { selectedItem = $0.map { SelectedTimelineItem(id: $0) } }
                )
            )
            .ignoresSafeArea()
            .accessibilityIdentifier("timelineGrid")

            if showMonthSidebar && !timelineManager.monthIndex.isEmpty {
                TimelineMonthSidebar(timelineManager: timelineManager)
            }
        }
    }
}

struct TimelineCollectionView: UIViewRepresentable {
    @ObservedObject var timelineManager: TimelineManager
    @Binding var selectedItemId: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(timelineManager: timelineManager, selectedItemId: $selectedItemId)
    }

    // Creates the UIKit timeline grid and emits the first collection-view creation milestone.
    func makeUIView(context: Context) -> UICollectionView {
        let layout = TimelineGridLayout()
        layout.minimumLineSpacing = TimelineGridMetrics.spacing
        layout.minimumInteritemSpacing = TimelineGridMetrics.spacing
        layout.sectionInset = .zero
        // The row is measured against the content inset. Horizontal
        // insets stay 0 so that width is the full grid, not the safe area.
        layout.sectionInsetReference = .fromContentInset

        let collectionView = InitialLayoutCollectionView(frame: .zero, collectionViewLayout: layout)
        AppSignposts.event("TimelineCollectionViewCreated")
        collectionView.backgroundColor = .systemBackground
        // Automatic adjustment keeps the vertical safe area, so the first
        // and last rows still clear the bars. The horizontal part is
        // cancelled in the collection view, or landscape gains side margins.
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(TimelineCollectionCell.self, forCellWithReuseIdentifier: TimelineCollectionCell.reuseIdentifier)
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
    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.updateReferences(timelineManager: timelineManager, selectedItemId: $selectedItemId)
        context.coordinator.performInitialScrollIfNeeded()
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        private var timelineManager: TimelineManager
        private var selectedItemId: Binding<String?>
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
        private let edgeThreshold = 24

        init(timelineManager: TimelineManager, selectedItemId: Binding<String?>) {
            self.timelineManager = timelineManager
            self.selectedItemId = selectedItemId
            self.lastKnownTotalCount = timelineManager.totalCount
        }

        func attach(collectionView: UICollectionView) {
            self.collectionView = collectionView
            bindToManager()
        }

        func updateReferences(timelineManager: TimelineManager, selectedItemId: Binding<String?>) {
            self.timelineManager = timelineManager
            self.selectedItemId = selectedItemId
        }

        private func bindToManager() {
            timelineManager.loadGenerationPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    if self.timelineManager.isGridScrolling || self.isProgrammaticMonthJumpInFlight {
                        self.hasPendingReconfigure = true
                        return
                    }
                    self.reconfigureVisibleCells()
                }
                .store(in: &cancellables)

            timelineManager.$totalCount
                .receive(on: DispatchQueue.main)
                .sink { [weak self] updatedCount in
                    guard let self, let collectionView = self.collectionView else { return }
                    guard self.lastKnownTotalCount != updatedCount else { return }
                    self.lastKnownTotalCount = updatedCount
                    // The cell still shows the photo from before this change.
                    // The manager's index for that row has already moved, so
                    // reading the manager here would anchor the wrong photo.
                    let preserved = self.hasCommittedInitialPosition
                        ? self.preservedVisibleItem(in: collectionView)
                        : nil
                    collectionView.reloadData()
                    collectionView.layoutIfNeeded()
                    if let preserved,
                       let newIndex = self.timelineManager.index(ofItemId: preserved.itemId) {
                        let restored = self.restoreVisibleTopAnchor(
                            (IndexPath(item: newIndex, section: 0), preserved.offsetFromItemTop),
                            in: collectionView
                        )
                        if restored {
                            collectionView.layoutIfNeeded()
                            self.timelineManager.savedContentOffset = collectionView.contentOffset
                            self.timelineManager.savedViewportAnchorIndex = newIndex
                            self.timelineManager.savedViewportAnchorOffsetFromItemTop = preserved.offsetFromItemTop
                            self.lastStableContentOffsetY = collectionView.contentOffset.y
                            self.publishViewportMonth(in: collectionView, force: true)
                        }
                    }
                    self.performInitialScrollIfNeeded()
                }
                .store(in: &cancellables)

            timelineManager.$scrollTargetIndex
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

        // Restores a previously saved scroll position, or anchors to the newest row on first launch.
        func performInitialScrollIfNeeded() {
            guard !hasPerformedInitialScroll,
                  timelineManager.totalCount > 0,
                  let collectionView else { return }
            timelineManager.savedGridWidth = collectionView.bounds.width
            let newestItemIndex = timelineManager.totalCount - 1
            collectionView.layoutIfNeeded()
            guard collectionView.window != nil else { return }
            guard collectionView.bounds.height > 0 else { return }
            guard collectionView.contentSize.height > 0 else { return }
            guard collectionView.numberOfItems(inSection: 0) > newestItemIndex else { return }
            guard !collectionView.isDragging, !collectionView.isDecelerating else { return }

            if let saved = timelineManager.savedContentOffset {
                hasPerformedInitialScroll = true
                var restoredOffset = saved
                if let anchorIndex = timelineManager.savedViewportAnchorIndex,
                   let anchorOffset = timelineManager.savedViewportAnchorOffsetFromItemTop {
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
                AppSignposts.event("TimelineGridRestoredScroll")
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
            AppSignposts.event("TimelineGridFirstLayout")
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
            if visible.count < 2, timelineManager.totalCount > 1 {
                return
            }
            guard let top = topVisibleItemIndex(in: collectionView) else { return }
            if !force, top == lastKnownTopVisibleIndex { return }
            lastKnownTopVisibleIndex = top
            timelineManager.updateCurrentMonth(for: top, force: force)
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
            if let index = timelineManager.savedViewportAnchorIndex,
               let offset = timelineManager.savedViewportAnchorOffsetFromItemTop {
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
                guard let index = timelineManager.savedViewportAnchorIndex,
                      let offset = timelineManager.savedViewportAnchorOffsetFromItemTop else {
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
            timelineManager.savedContentOffset = collectionView.contentOffset
            timelineManager.savedGridWidth = collectionView.bounds.width
            lastStableContentOffsetY = collectionView.contentOffset.y
            collectionView.layoutIfNeeded()
            if let pinnedTop {
                timelineManager.savedViewportAnchorIndex = pinnedTop.indexPath.item
                timelineManager.savedViewportAnchorOffsetFromItemTop = pinnedTop.offsetFromItemTop
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
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
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
                timelineManager.savedContentOffset = scrollView.contentOffset
                lastStableContentOffsetY = scrollView.contentOffset.y
            }
            guard let collectionView = scrollView as? UICollectionView else { return }
            timelineManager.savedGridWidth = collectionView.bounds.width
            guard !isProgrammaticMonthJumpInFlight else { return }
            let visibleCount = collectionView.indexPathsForVisibleItems.count
            let layoutSettled = visibleCount >= 2 || timelineManager.totalCount <= 1
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
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if activeRotationAnchor != nil {
                finishRotationHold(in: collectionView)
            }
            isProgrammaticMonthJumpInFlight = false
            (scrollView as? InitialLayoutCollectionView)?.redirectsTopAnchorsToBottom = true
            timelineManager.setGridScrolling(true)
        }

        // Clears drag flag when user lifts finger and no deceleration remains.
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                timelineManager.setGridScrolling(false)
                flushPendingReconfigure()
                if let collectionView = scrollView as? UICollectionView {
                    rememberCenterAnchor(in: collectionView)
                    publishViewportMonth(in: collectionView, force: true)
                }
            }
        }

        // Clears drag flag after inertial scrolling settles so sidebar may resume animated autoscroll.
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            timelineManager.setGridScrolling(false)
            flushPendingReconfigure()
            if let collectionView = scrollView as? UICollectionView {
                rememberCenterAnchor(in: collectionView)
                publishViewportMonth(in: collectionView, force: true)
            }
        }

        // Tab reselect and status-bar taps ask for the top. The timeline is
        // oldest-first, so the end someone is trying to reach is the newest
        // row. Returning false keeps UIKit from also scrolling to the top.
        // This is not a month jump: the sidebar should follow the viewport
        // to the newest month when the animation ends.
        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            let inset = scrollView.adjustedContentInset
            let targetY = TimelineInitialBottomAnchor.targetYOffset(
                contentHeight: scrollView.contentSize.height,
                viewportHeight: scrollView.bounds.height,
                topInset: inset.top,
                bottomInset: inset.bottom
            )
            guard abs(scrollView.contentOffset.y - targetY) > 0.5 else { return false }
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: targetY),
                animated: true
            )
            return false
        }

        // Ends a programmatic scroll. A month jump keeps the tapped month
        // highlighted: the last month cannot reach the top, and republishing
        // the viewport month would snap the sidebar back to the earlier
        // month still visible there. Hand scrolling clears the flag in
        // scrollViewWillBeginDragging and tracks the viewport again.
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            let wasMonthJump = isProgrammaticMonthJumpInFlight
            isProgrammaticMonthJumpInFlight = false
            (scrollView as? InitialLayoutCollectionView)?.redirectsTopAnchorsToBottom = true
            timelineManager.setGridScrolling(false)
            flushPendingReconfigure()
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
            guard index >= 0, index < timelineManager.totalCount else {
                isProgrammaticMonthJumpInFlight = false
                timelineManager.scrollTargetIndex = nil
                return
            }
            let indexPath = IndexPath(item: index, section: 0)
            guard collectionView.numberOfItems(inSection: 0) > index else {
                isProgrammaticMonthJumpInFlight = false
                timelineManager.scrollTargetIndex = nil
                return
            }
            collectionView.layoutIfNeeded()
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                isProgrammaticMonthJumpInFlight = false
                timelineManager.scrollTargetIndex = nil
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
            timelineManager.scrollTargetIndex = nil
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
                  let cell = collectionView.cellForItem(at: anchor.indexPath) as? TimelineCollectionCell,
                  let itemId = cell.currentItemId else {
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
                timelineManager.savedViewportAnchorIndex = top.indexPath.item
                timelineManager.savedViewportAnchorOffsetFromItemTop = top.offsetFromItemTop
                return
            }
            // The top edge of the bounds, not a point below the safe area.
            // Adding the inset named the next row and the sidebar pinned that.
            let probeY = collectionView.contentOffset.y + 0.5
            let row = min(max(Int(floor(probeY / pitch)), 0), max((count - 1) / metrics.columns, 0))
            let index = min(row * metrics.columns, count - 1)
            let minY = CGFloat(row) * pitch
            timelineManager.savedViewportAnchorIndex = index
            timelineManager.savedViewportAnchorOffsetFromItemTop = collectionView.contentOffset.y - minY
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
            timelineManager.savedContentOffset = settledView.contentOffset
            timelineManager.savedGridWidth = settledView.bounds.width
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

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            timelineManager.totalCount
        }

        // Binds one visible cell to sparse timeline state and triggers image loading when data is available.
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TimelineCollectionCell.reuseIdentifier,
                for: indexPath
            ) as? TimelineCollectionCell else {
                return UICollectionViewCell()
            }

            let index = indexPath.item
            if let item = timelineManager.item(at: index) {
                cell.configure(item: item, timelineManager: timelineManager)
            } else {
                cell.configurePlaceholder()
                timelineManager.schedulePagingIfNeeded(around: index, edgeThreshold: edgeThreshold)
            }
            return cell
        }

        // Tracks visible timeline IDs and schedules coalesced sparse paging near viewport edges.
        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            let index = indexPath.item
            if let item = timelineManager.item(at: index) {
                TimelineRenderMilestoneTracker.shared.trackVisibleItem(item.id)
            }
            timelineManager.itemDidAppear(at: index)
            timelineManager.schedulePagingIfNeeded(around: index, edgeThreshold: edgeThreshold)
        }

        // Removes no-longer-visible IDs from viewport hydration tracking.
        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            if let timelineCell = cell as? TimelineCollectionCell,
               let itemId = timelineCell.currentItemId {
                TimelineRenderMilestoneTracker.shared.untrackVisibleItem(itemId)
            }
            timelineManager.itemDidDisappear(at: indexPath.item)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let item = timelineManager.item(at: indexPath.item) else { return }
            selectedItemId.wrappedValue = item.id
        }

        // Sizes every thumbnail so the row fills the grid width. A wider
        // row grows the cells slightly instead of leaving side margins.
        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
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

    // Tab reselect and the status bar scroll to the top. The oldest photos
    // are there, so the request is carried to the newest row instead.
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if suspendsTopRedirect {
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

    // A programmatic jump to the top is the system scroll-to-top gesture.
    // Dragging and deceleration move the same distance in small steps, and
    // those have to be able to reach the oldest photos.
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

// Tracks one-shot first-render milestones so startup profiling can separate metadata-ready from pixel-ready states.
@MainActor
final class TimelineRenderMilestoneTracker {
    static let shared = TimelineRenderMilestoneTracker()

    private var hasEmittedFirstVisibleThumbnail = false
    private var hasEmittedViewportHydrated = false
    private var visiblePendingItemIds: Set<String> = []

    private init() {}

    // Resets one-shot viewport milestones at the start of a fresh timeline load.
    func resetForNewTimelineLoad() {
        hasEmittedViewportHydrated = false
        visiblePendingItemIds.removeAll()
    }

    // Records one item as visible so viewport hydration can complete only after each visible cell resolves.
    func trackVisibleItem(_ itemId: String) {
        visiblePendingItemIds.insert(itemId)
    }

    // Stops tracking one item when it is no longer visible.
    func untrackVisibleItem(_ itemId: String) {
        visiblePendingItemIds.remove(itemId)
    }

    // Marks one visible item as resolved and emits first-thumbnail/viewport-hydrated milestones when reached.
    func markVisibleItemResolved(itemId: String, didRenderImage: Bool) {
        if didRenderImage && !hasEmittedFirstVisibleThumbnail {
            hasEmittedFirstVisibleThumbnail = true
            AppSignposts.event("TimelineFirstVisibleThumbnailRendered")
        }
        guard visiblePendingItemIds.contains(itemId) else { return }
        visiblePendingItemIds.remove(itemId)
        guard !hasEmittedViewportHydrated, visiblePendingItemIds.isEmpty else { return }
        hasEmittedViewportHydrated = true
        AppSignposts.event("TimelineVisibleViewportHydrated")
    }
}

final class TimelineCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "TimelineCollectionCell"

    private let imageView = UIImageView()
    private let placeholderIcon = UIImageView(image: UIImage(systemName: "photo"))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let durationLabel = UILabel()
    private var imageCancellable: AnyCancellable?
    private var imageLoader: ImageLoader?
    private var configuredItemId: String?
    fileprivate var currentItemId: String? { configuredItemId }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = [.button]
        contentView.addSubview(imageView)

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.tintColor = .secondaryLabel
        contentView.addSubview(placeholderIcon)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        durationLabel.layer.cornerRadius = 3
        durationLabel.layer.masksToBounds = true
        durationLabel.textAlignment = .center
        durationLabel.isHidden = true
        contentView.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            placeholderIcon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            durationLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageCancellable?.cancel()
        imageCancellable = nil
        imageLoader?.cancelLoading()
        imageLoader = nil
        configuredItemId = nil
        imageView.image = nil
        contentView.backgroundColor = UIColor.systemGray6
        placeholderIcon.isHidden = false
        spinner.stopAnimating()
        durationLabel.isHidden = true
        durationLabel.text = nil
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        imageView.accessibilityIdentifier = nil
        imageView.accessibilityLabel = nil
    }

    func configurePlaceholder() {
        imageCancellable?.cancel()
        imageLoader?.cancelLoading()
        imageLoader = nil
        configuredItemId = nil
        imageView.image = nil
        contentView.backgroundColor = UIColor.systemGray6
        placeholderIcon.isHidden = true
        spinner.startAnimating()
        durationLabel.isHidden = true
        durationLabel.text = nil
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        imageView.accessibilityIdentifier = nil
        imageView.accessibilityLabel = nil
    }

    // Configures one cell and reports thumbnail resolution milestones for the current visible item.
    func configure(item: TimelineItem, timelineManager: TimelineManager) {
        let isSameItem = configuredItemId == item.id
        configuredItemId = item.id
        applyDurationLabel(for: item)
        accessibilityIdentifier = "timelinePhoto_\(item.id)"
        accessibilityLabel = item.id
        imageView.accessibilityIdentifier = "timelinePhoto_\(item.id)"
        imageView.accessibilityLabel = item.id

        // Keeps in-flight LFS fetches alive across sparse-page reconfigure
        // passes so slow mTLS thumbnail downloads are not cancelled mid-flight.
        if TimelineThumbnailLoadPolicy.shouldPreserveLoader(
            isSameItem: isSameItem,
            hasImage: imageLoader?.image != nil || imageView.image != nil,
            isLoading: imageLoader?.isLoading == true
        ) {
            if let image = imageLoader?.image ?? imageView.image {
                imageView.image = image
                contentView.backgroundColor = .clear
                spinner.stopAnimating()
                placeholderIcon.isHidden = true
            }
            return
        }

        imageCancellable?.cancel()
        imageLoader?.cancelLoading()

        if !isSameItem {
            imageView.image = nil
        }
        if imageView.image == nil {
            contentView.backgroundColor = UIColor.systemGray6
            spinner.startAnimating()
            placeholderIcon.isHidden = true
        } else {
            contentView.backgroundColor = .clear
            spinner.stopAnimating()
            placeholderIcon.isHidden = true
        }

        let loader = ImageLoader(item: item, timelineManager: timelineManager) { didRenderImage in
            Task { @MainActor in
                TimelineRenderMilestoneTracker.shared.markVisibleItemResolved(itemId: item.id, didRenderImage: didRenderImage)
            }
        }
        imageLoader = loader
        imageCancellable = loader.$image
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let self else { return }
                if let image {
                    self.imageView.image = image
                    self.contentView.backgroundColor = .clear
                    self.spinner.stopAnimating()
                    self.placeholderIcon.isHidden = true
                } else if loader.isLoading {
                    if self.imageView.image == nil {
                        self.spinner.startAnimating()
                    }
                } else if self.imageView.image == nil {
                    self.spinner.stopAnimating()
                    self.placeholderIcon.isHidden = false
                }
            }
        loader.loadImage()
    }

    // Updates the video duration badge independently of thumbnail load lifecycle.
    private func applyDurationLabel(for item: TimelineItem) {
        if item.original.spec.mediaType == "video", let duration = item.original.spec.duration {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            durationLabel.text = " \(minutes):\(String(format: "%02d", seconds)) "
            durationLabel.isHidden = false
        } else {
            durationLabel.isHidden = true
            durationLabel.text = nil
        }
    }
}

// Decides whether a timeline cell should keep its current ImageLoader across
// reconfigure passes so sparse paging does not abort in-flight LFS work.
enum TimelineThumbnailLoadPolicy {
    static func shouldPreserveLoader(isSameItem: Bool, hasImage: Bool, isLoading: Bool) -> Bool {
        isSameItem && (hasImage || isLoading)
    }
}

// Thin SwiftUI wrapper that presents the UIKit full-screen media page
// controller so the rest of the SwiftUI view hierarchy can still use
// fullScreenCover and @Environment(\.dismiss). Holds the manager by
// value so commit-driven TimelineManager publishes cannot rebuild the
// live zoom session.
struct FullScreenMediaView: View {
    let initialItemId: String
    let timelineManager: TimelineManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FullScreenMediaRepresentable(
            initialItemId: initialItemId,
            timelineManager: timelineManager,
            onDismiss: { dismiss() }
        )
        .ignoresSafeArea()
        .statusBar(hidden: true)
    }
}

/// Bridges the UIKit FullScreenMediaPageViewController into SwiftUI.
struct FullScreenMediaRepresentable: UIViewControllerRepresentable {
    let initialItemId: String
    let timelineManager: TimelineManager
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> FullScreenMediaPageViewController {
        FullScreenMediaPageViewController(
            initialItemId: initialItemId,
            timelineManager: timelineManager,
            onDismiss: onDismiss
        )
    }

    func updateUIViewController(_ uiViewController: FullScreenMediaPageViewController, context: Context) {}
}

struct MediaInfoContent: View {
    let item: TimelineItem

    // Uploads store a UTI in mimeType. Details show the file extension
    // so an already-uploaded library reads HEIC instead of public.heic,
    // without changing the stored value.
    static func displayFormat(for storedType: String) -> String {
        let type = UTType(mimeType: storedType) ?? UTType(storedType)
        guard let fileExtension = type?.preferredFilenameExtension else {
            return storedType
        }
        return fileExtension.uppercased()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Date section
            if let takenAt = item.original.spec.takenAt {
                InfoSection(title: "Captured") {
                    Text(formatDate(takenAt))
                        .font(.body)
                }
            } else if let guessedTakenAt = item.original.spec.guessedTakenAt {
                InfoSection(title: "Captured (estimated)") {
                    Text(formatDate(guessedTakenAt))
                        .font(.body)
                }
            }
            
            if let modifiedAt = item.original.spec.modifiedAt {
                InfoSection(title: "Modified") {
                    Text(formatDateString(modifiedAt))
                        .font(.body)
                }
            }
            
            // Dimensions & Size
            InfoSection(title: "Details") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Dimensions:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(item.original.spec.width) × \(item.original.spec.height)")
                    }
                    
                    HStack {
                        Text("Size:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatFileSize(item.original.spec.filesize))
                    }
                    
                    HStack {
                        Text("Type:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(item.original.spec.mediaType.capitalized)
                    }
                    
                    if let mimeType = item.original.spec.mimeType {
                        HStack {
                            Text("Format:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(MediaInfoContent.displayFormat(for: mimeType))
                        }
                    }
                    
                    if let duration = item.original.spec.duration {
                        HStack {
                            Text("Duration:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatDuration(duration))
                        }
                    }
                }
                .font(.body)
            }
            
            // Location
            if let location = item.original.spec.location {
                InfoSection(title: "Location") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Latitude:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.6f°", location.latitude))
                        }
                        
                        HStack {
                            Text("Longitude:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.6f°", location.longitude))
                        }
                        
                        if let altitude = location.altitude {
                            HStack {
                                Text("Altitude:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.1f m", altitude))
                            }
                        }
                    }
                    .font(.body)
                }
            }
            
            // Device & Storage
            InfoSection(title: "Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Device:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(item.original.metadata.deviceSpace)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    HStack {
                        Text("ID:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(item.original.spec.id)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)
                    }
                    
                    if item.original.spec.isFavorite {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.red)
                            Text("Favorite")
                        }
                    }
                }
                .font(.body)
            }
            
            // Original Path
            if !item.original.spec.path.isEmpty {
                InfoSection(title: "Original Path") {
                    Text(item.original.spec.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
    }
    
    private func formatDate(_ date: Date) -> String {
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .long
        displayFormatter.timeStyle = .short
        return displayFormatter.string(from: date)
    }
    
    private func formatDateString(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else {
            return isoString
        }
        
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .long
        displayFormatter.timeStyle = .short
        return displayFormatter.string(from: date)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            content
        }
    }
}

enum FullResolutionImageLoadError: Error {
    case decodeFailed
    case repositoryNotAvailable
    case lfsClientNotAvailable
}

@MainActor
final class FullResolutionImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private weak var timelineManager: TimelineManager?
    private var loadTask: Task<Void, Never>?
    private var qualityMonitoringTask: Task<Void, Never>?
    private var directPlayLoader: DirectPlayResourceLoader?
    // Retained for the lifetime of playback because AVAssetResourceLoader holds
    // its delegate weakly; letting it deallocate stalls the stream.
    private var hlsLoader: HLSResourceLoader?
    // Stored so dismiss teardown can remove observers that would otherwise
    // leak and keep a discarded player item alive.
    private var playerItemObservers: [NSObjectProtocol] = []
    nonisolated static let playbackMIMETypeAssetOptionKey = "AVURLAssetOutOfBandMIMETypeKey"

    // Carries request-scoped playback values so backend decrypting services can stream plaintext without KEK access.
    struct VideoPlaybackContext {
        let encryptedOID: String
        let dekBase64: String
    }
    
    init(timelineManager: TimelineManager) {
        self.timelineManager = timelineManager
    }
    
    /// Fetches and decodes a full-resolution photo, preferring local
    /// Photo Library bytes when enabled so fullscreen open can avoid LFS
    /// latency on the capturing device.
    /// Shared between the per-page loader and the background preloader
    /// so both paths hit the same local/LFS fallback pipeline.
    static func loadOriginalImage(
        for item: TimelineItem,
        priority: ImageLoadPriority,
        repository: Repository,
        lfsClient: GitLFS,
        photoLibrary: PhotoLibraryProviding? = nil
    ) async throws -> UIImage {
        if let localImage = await loadLocalOriginalImageIfAvailable(
            for: item,
            photoLibrary: photoLibrary
        ) {
            return localImage
        }

        let mediaData = try await loadRemoteOriginalImageData(
            for: item,
            priority: priority,
            repository: repository,
            lfsClient: lfsClient
        )
        guard let loadedImage = await decodeOriginalImage(mediaData) else {
            throw FullResolutionImageLoadError.decodeFailed
        }
        return loadedImage
    }

    /// Returns the original photo bytes for export. Sharing and saving
    /// need the stored file, not a re-encoded UIImage, so a camera-roll
    /// copy stays byte-identical and photo sync does not upload it again.
    static func loadOriginalImageData(
        for item: TimelineItem,
        priority: ImageLoadPriority,
        repository: Repository?,
        lfsClient: GitLFS?,
        photoLibrary: PhotoLibraryProviding? = nil
    ) async throws -> Data {
        if let localData = await loadLocalOriginalImageDataIfAvailable(
            for: item,
            photoLibrary: photoLibrary
        ) {
            return localData
        }
        guard let repository else {
            throw FullResolutionImageLoadError.repositoryNotAvailable
        }
        guard let lfsClient else {
            throw FullResolutionImageLoadError.lfsClientNotAvailable
        }
        return try await loadRemoteOriginalImageData(
            for: item,
            priority: priority,
            repository: repository,
            lfsClient: lfsClient
        )
    }

    // Downloads the encrypted original and decrypts it. Callers that
    // already resolved local Photos bytes should not reach this.
    private static func loadRemoteOriginalImageData(
        for item: TimelineItem,
        priority: ImageLoadPriority,
        repository: Repository,
        lfsClient: GitLFS
    ) async throws -> Data {
        let deviceSpace = item.original.metadata.deviceSpace
        let originalPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(item.original.metadata.name))"
        let mediaData = try await ImageDiskCacheManager.shared.loadImageData(
            kind: .original,
            priority: priority,
            itemId: item.id,
            lfsPath: originalPath,
            repository: repository,
            lfsClient: lfsClient
        )
        try Task.checkCancellation()
        return mediaData
    }

    // Decodes off the main actor so a large original does not stall
    // fullscreen gestures.
    private static func decodeOriginalImage(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }

    // Retries a fullscreen photo that was refused because the tailnet
    // join had not finished. The request fails before any bytes move, so
    // waiting for the join and trying again is what gets the photo on
    // screen instead of leaving the spinner up.
    static func loadWhenConnected<T>(
        waitForNetwork: () async throws -> Void,
        _ load: () async throws -> T
    ) async throws -> T {
        while true {
            do {
                return try await load()
            } catch TailnetSessionRouter.RoutingError.notConnectedYet {
                try await waitForNetwork()
                try Task.checkCancellation()
            }
        }
    }

    // Resolves full-resolution image bytes from local Photos when the
    // performance toggle is enabled. Returns nil so callers fall back
    // to LFS when permission, identifiers, or the local file are missing.
    private static func loadLocalOriginalImageDataIfAvailable(
        for item: TimelineItem,
        photoLibrary: PhotoLibraryProviding?
    ) async -> Data? {
        guard CacheSettingsManager.shared.localThumbnailsEnabled else {
            return nil
        }
        guard let photoLibrary, photoLibrary.isAuthorized else {
            return nil
        }
        guard let localID = item.original.spec.localID, !localID.isEmpty else {
            return nil
        }
        return await photoLibrary.getOriginalImageData(forLocalIdentifier: localID)
    }

    // Decodes local Photos bytes for display. A file that cannot be
    // decoded falls through to LFS so one bad local copy does not hide
    // the original stored in the library.
    private static func loadLocalOriginalImageIfAvailable(
        for item: TimelineItem,
        photoLibrary: PhotoLibraryProviding?
    ) async -> UIImage? {
        guard let localData = await loadLocalOriginalImageDataIfAvailable(
            for: item,
            photoLibrary: photoLibrary
        ) else {
            return nil
        }
        let localImage = await decodeOriginalImage(localData)
        if localImage == nil {
            logWarning("Failed to decode local original image for \(item.id); falling back to LFS", context: "FullScreen")
        } else {
            logDebug("Loaded local full-resolution image for \(item.id)", context: "FullScreen")
        }
        return localImage
    }

    // Loads fullscreen media while routing encrypted videos through decryptd-compatible playback configuration.
    func loadOriginal(for item: TimelineItem, isVideo: Bool) {
        guard (image == nil && player == nil) && !isLoading else { return }
        
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            errorMessage = nil
            
            do {
                let mediaType = isVideo ? "video" : "photo"
                logDebug("Loading original \(mediaType) for \(item.id)", context: "FullScreen")

                if isVideo {
                    try await playVideo(item: item)
                } else {
                    if let localImage = await Self.loadLocalOriginalImageIfAvailable(
                        for: item,
                        photoLibrary: timelineManager?.photoLibrary
                    ) {
                        self.image = localImage
                        logDebug("Successfully loaded local original image (\(localImage.size.width)x\(localImage.size.height))", context: "FullScreen")
                        isLoading = false
                        return
                    }

                    guard let repository = timelineManager?.repository else {
                        logError("Repository not available in TimelineManager", context: "FullScreen")
                        errorMessage = "Repository not available"
                        isLoading = false
                        return
                    }

                    guard let lfsClient = timelineManager?.lfsClient else {
                        logError("LFS client not available in TimelineManager", context: "FullScreen")
                        errorMessage = "LFS client not available"
                        isLoading = false
                        return
                    }

                    let loadedImage = try await Self.loadWhenConnected(
                        waitForNetwork: {
                            try await TailnetBootstrap.shared.waitUntilJoined()
                        }
                    ) {
                        try await Self.loadOriginalImage(
                            for: item,
                            priority: .fullscreenCurrent,
                            repository: repository,
                            lfsClient: lfsClient
                        )
                    }
                    self.image = loadedImage
                    logDebug("Successfully loaded original image (\(loadedImage.size.width)x\(loadedImage.size.height))", context: "FullScreen")
                }
            } catch {
                if !Task.isCancelled {
                    logError("Failed to load original: \(error.localizedDescription)", context: "FullScreen")
                    errorMessage = error.localizedDescription
                }
            }
            
            isLoading = false
        }
    }

    // Builds encrypted playback context and starts AVPlayer with request-scoped DEK headers for decryptd.
    private func playVideo(item: TimelineItem) async throws {
        if await loadLocalVideoIfAvailable(for: item) {
            return
        }

        let duration = item.original.spec.duration ?? 0
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")

        let playbackContext: VideoPlaybackContext?
        if isUITesting {
            playbackContext = nil
        } else {
            guard let repository = timelineManager?.repository else {
                throw TimelineError.repositoryNotInitialized
            }
            playbackContext = try Self.resolveVideoPlaybackContext(item: item, repository: repository)
        }

        let objectIDForPlayback = playbackContext?.encryptedOID ?? item.original.spec.sha256
        let playbackMethod = PlaybackSettingsManager.selectPlaybackMethod(for: item)
        let playbackURL = try Self.makePlaybackURL(
            playbackMethod: playbackMethod,
            objectID: objectIDForPlayback,
            duration: duration,
            isUITesting: isUITesting,
            lfsURLString: ServerConfigurationManager.shared.loadLFSURL(),
            gitURLString: ServerConfigurationManager.shared.loadURL()
        )
        let usesHLS = playbackMethod == .transcode

        let modeDescription = usesHLS ? "HLS transcode" : "direct play"
        log("Streaming video via \(modeDescription): \(playbackURL.absoluteString)", context: "FullScreen")


        // Create AVURLAsset without preloading media bytes; AVFoundation streams on demand.
        let headerFields: [String: String]?
        if let playbackContext {
            headerFields = [
                "X-Replycant-DEK": playbackContext.dekBase64
            ]
        } else {
            headerFields = nil
        }

        // Both playback paths reach their backend through gitd's mTLS endpoint,
        // which AVPlayer's own HTTP stack cannot authenticate against. Routing
        // every sub-request through a custom-scheme resource loader is what lets
        // the device identity be presented.
        let clientIdentity = ClientIdentityManager.shared.loadSecIdentity()
        let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate()

        let asset: AVURLAsset
        if usesHLS {
            let loader = HLSResourceLoader(
                headers: headerFields ?? [:],
                clientIdentity: clientIdentity,
                pinnedCA: pinnedCA
            )
            self.hlsLoader = loader
            guard let customURL = HLSResourceLoader.customSchemeURL(from: playbackURL) else {
                logError("Failed to build custom-scheme URL for HLS playback", context: "FullScreen")
                errorMessage = "Invalid video URL"
                isLoading = false
                return
            }
            asset = AVURLAsset(url: customURL)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue.global(qos: .userInitiated))
        } else {
            let mimeType = item.original.spec.mimeType ?? "video/mp4"
            let loader = DirectPlayResourceLoader(
                httpURL: playbackURL,
                headers: headerFields ?? [:],
                mimeType: mimeType,
                clientIdentity: clientIdentity,
                pinnedCA: pinnedCA
            )
            self.directPlayLoader = loader
            guard let customURL = DirectPlayResourceLoader.customSchemeURL(from: playbackURL) else {
                logError("Failed to build custom-scheme URL for direct play", context: "FullScreen")
                errorMessage = "Invalid video URL"
                isLoading = false
                return
            }
            asset = AVURLAsset(url: customURL)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue.global(qos: .userInitiated))
        }

        let playerItem = AVPlayerItem(asset: asset)

        playerItem.preferredForwardBufferDuration = usesHLS ? 2.0 : 8.0
        if usesHLS {
            // Configure player item for HLS adaptive bitrate streaming.
            playerItem.preferredPeakBitRate = 0
            playerItem.preferredMaximumResolution = CGSize(width: 3840, height: 2160)
            if #available(iOS 15.0, *) {
                // Starts on an eligible high-quality variant and lets ABR adapt afterward.
                playerItem.startsOnFirstEligibleVariant = true
            }
            logDebug("Configured HLS playerItem - preferredPeakBitRate: unlimited (0), preferredMaxResolution: \(playerItem.preferredMaximumResolution), bufferDuration: \(playerItem.preferredForwardBufferDuration)", context: "FullScreen")
        } else {
            logDebug("Configured direct-play playerItem with bufferDuration: \(playerItem.preferredForwardBufferDuration)", context: "FullScreen")
        }
        
        // Ensure automatic stalling prevention is enabled (default, but explicit for clarity)
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        if usesHLS {
            // Observe access log to track bitrate changes for adaptive streams.
            playerItemObservers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: playerItem,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    self.logAccessLog(playerItem: playerItem)
                }
            })
        }
        
        let avPlayer = AVPlayer(playerItem: playerItem)
        // Direct MP4 seeks need AVPlayer to preserve play intent while new
        // byte ranges buffer; HLS keeps the faster startup behavior.
        avPlayer.automaticallyWaitsToMinimizeStalling = !usesHLS
        if !usesHLS, let directPlayLoader = self.directPlayLoader {
            wireDirectPlaySeekResume(on: directPlayLoader, player: avPlayer)
        }
        self.player = avPlayer
        logDebug("Successfully created \(modeDescription) player for video (LFS OID: \(objectIDForPlayback))", context: "FullScreen")
        logDebug("Player configured - automaticallyWaitsToMinimizeStalling: \(avPlayer.automaticallyWaitsToMinimizeStalling)", context: "FullScreen")
        qualityMonitoringTask?.cancel()
        qualityMonitoringTask = nil

        // Surfaces silent AVPlayerItem failures so direct-play issues are diagnosable from logs.
        playerItemObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { notification in
            Task { @MainActor in
                let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                logError("PlayerItem failed to play to end: \(err?.localizedDescription ?? "unknown")", context: "FullScreen")
            }
        })
        playerItemObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if let errorLog = playerItem.errorLog(), let last = errorLog.events.last {
                    logError("[ERROR LOG] status=\(last.errorStatusCode) domain=\(last.errorDomain) comment=\(last.errorComment ?? "none") uri=\(last.uri ?? "none")", context: "FullScreen")
                }
            }
        })

        if usesHLS {
            // Logs quality evolution for adaptive streams to validate bitrate switching behavior.
            qualityMonitoringTask = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await self.logCurrentVideoQuality(playerItem: playerItem)

                // Set up periodic quality logging every 2 seconds
                await self.startQualityMonitoring(playerItem: playerItem)
            }
        }
    }

    // Preserves play intent across direct-play byte-range replacement so
    // buffering updates do not leave fullscreen video unexpectedly paused.
    // Weak self plus an owner check are required because a dismissed
    // AVPlayer can still be retained by the dismiss animation; capturing
    // the player weakly is not enough to outrun a late resume callback.
    private func wireDirectPlaySeekResume(
        on loader: DirectPlayResourceLoader,
        player: AVPlayer,
        armResume: Bool = false
    ) {
        var seekResumeGate = DirectPlayResumeGate()
        if armResume {
            _ = seekResumeGate.handleReplacementStarted(isPlayingOrWaiting: true)
        }
        loader.onSeekRangeReplacementStarted = { [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            let shouldPause = seekResumeGate.handleReplacementStarted(
                isPlayingOrWaiting: player.rate > 0
                    || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            )
            if shouldPause {
                player.pause()
            }
        }
        loader.onSeekRangeReplacementReady = { [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            guard seekResumeGate.handleReplacementReady() else { return }
            player.play()
        }
    }

    // Stops playback authoritatively on dismiss so a late seek-resume callback
    // cannot restart audio after the fullscreen UI is gone.
    func teardownPlayback() {
        directPlayLoader?.onSeekRangeReplacementStarted = nil
        directPlayLoader?.onSeekRangeReplacementReady = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        for observer in playerItemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        playerItemObservers.removeAll()
        directPlayLoader?.invalidate()
        hlsLoader?.invalidate()
        directPlayLoader = nil
        hlsLoader = nil
        loadTask?.cancel()
        qualityMonitoringTask?.cancel()
        loadTask = nil
        qualityMonitoringTask = nil
        player = nil
    }

    // Publishes a Photos-library player when one exists so a metered
    // network can still autoplay a video that will not touch the network.
    // Returns false when playback has to stream the original from the server.
    func loadLocalVideoIfAvailable(for item: TimelineItem) async -> Bool {
        guard let localPlayer = await makeLocalVideoPlayerIfAvailable(for: item) else {
            return false
        }
        self.player = localPlayer
        qualityMonitoringTask?.cancel()
        qualityMonitoringTask = nil
        directPlayLoader = nil
        hlsLoader = nil
        logDebug("Loaded local video asset for \(item.id)", context: "FullScreen")
        return true
    }

    // Resolves a local video URL when the performance toggle is enabled so fullscreen playback can avoid server startup latency.
    // Returns nil to preserve existing streaming fallback when permission, local identifiers, or local files are unavailable.
    private func makeLocalVideoPlayerIfAvailable(for item: TimelineItem) async -> AVPlayer? {
        guard CacheSettingsManager.shared.localThumbnailsEnabled else {
            return nil
        }
        guard let photoLibrary = timelineManager?.photoLibrary, photoLibrary.isAuthorized else {
            return nil
        }
        guard let localID = item.original.spec.localID, !localID.isEmpty else {
            return nil
        }
        guard let localURL = await photoLibrary.getVideoURL(forLocalIdentifier: localID) else {
            return nil
        }

        let asset = AVURLAsset(url: localURL)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2.0
        let localPlayer = AVPlayer(playerItem: playerItem)
        localPlayer.automaticallyWaitsToMinimizeStalling = true
        return localPlayer
    }

    // Centralizes URL construction so playback mode switching stays consistent across runtime and tests.
    nonisolated static func makePlaybackURL(
        playbackMethod: PlaybackMethod,
        objectID: String,
        duration: Double,
        isUITesting: Bool,
        lfsURLString: String?,
        gitURLString: String?
    ) throws -> URL {
        if isUITesting {
            guard
                let lfsURLString,
                let lfsURL = URL(string: lfsURLString),
                let host = lfsURL.host,
                let port = lfsURL.port
            else {
                throw URLError(.badURL)
            }
            let scheme = lfsURL.scheme ?? "http"
            let path: String
            switch playbackMethod {
            case .directPlay:
                path = "/objects/\(objectID)"
            case .transcode:
                path = "/hls/\(objectID)/\(duration)/playlist.m3u8"
            }
            guard let url = URL(string: "\(scheme)://\(host):\(port)\(path)") else {
                throw URLError(.badURL)
            }
            return url
        }

        // decryptd and transcoded publish no host ports; both are reached only
        // through gitd's mTLS-authenticated route prefixes on the git origin.
        guard let gitURLString else {
            throw URLError(.badURL)
        }

        let servicePath: String
        let resourcePath: String
        switch playbackMethod {
        case .directPlay:
            servicePath = "/decryptd"
            resourcePath = "/objects/\(objectID)"
        case .transcode:
            servicePath = "/transcoded"
            resourcePath = "/hls/\(objectID)/\(duration)/playlist.m3u8"
        }

        guard
            let serviceBase = ServerConfigurationManager.deriveServiceURL(from: gitURLString, path: servicePath),
            let url = URL(string: serviceBase + resourcePath)
        else {
            throw URLError(.badURL)
        }
        return url
    }

    // Supplies AVFoundation with request metadata needed by encrypted and extensionless media URLs.
    nonisolated static func makePlaybackAssetOptions(
        headerFields: [String: String]?,
        mimeType: String?,
        usesHLS: Bool
    ) -> [String: Any]? {
        var options: [String: Any] = [:]
        if let headerFields {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headerFields
        }
        if !usesHLS, let mimeType, !mimeType.isEmpty {
            options[playbackMIMETypeAssetOptionKey] = mimeType
        }
        return options.isEmpty ? nil : options
    }

    // Resolves encrypted object metadata and unwraps the per-object DEK locally to keep KEK off backend networks.
    static func resolveVideoPlaybackContext(item: TimelineItem, repository: Repository) throws -> VideoPlaybackContext {
        let deviceSpace = item.original.metadata.deviceSpace
        let pointerPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(item.original.metadata.name))"
        let pointerContent = try repository.readFile(at: pointerPath)
        let pointer = try EncryptedLFSPointer.parse(pointerContent)

        let kek = try KEKEpochManager(repository: repository).loadKEK(epoch: pointer.kekEpoch)
        guard let wrappedDEKData = Data(base64Encoded: pointer.wrappedDEK) else {
            throw EncryptedLFSError.invalidEncryptionMetadata
        }
        let dek = try EncryptionUtils.unwrapDEK(
            wrappedDEKData,
            withKEK: kek,
            kekEpoch: pointer.kekEpoch
        )
        let dekBase64 = dek.base64EncodedString()
        return VideoPlaybackContext(encryptedOID: pointer.oid, dekBase64: dekBase64)
    }

    // Logs current video quality from the player item's selected tracks
    private func logCurrentVideoQuality(playerItem: AVPlayerItem) async {
        guard let tracks = try? await playerItem.asset.load(.tracks) else {
            logWarning("Could not load tracks for quality logging", context: "FullScreen")
            return
        }

        // Find the currently selected video track
        let videoTracks = tracks.filter { $0.mediaType == .video }
        logDebug("Found \(videoTracks.count) video tracks", context: "FullScreen")
        
        // Check which track is currently selected by examining the player item's tracks
        for track in playerItem.tracks {
            if track.assetTrack?.mediaType == .video {
                if let assetTrack = track.assetTrack {
                    do {
                        let naturalSize = try await assetTrack.load(.naturalSize)
                        let estimatedDataRate = try? await assetTrack.load(.estimatedDataRate)

                        let width = Int(naturalSize.width)
                        let height = Int(naturalSize.height)
                        let bitrate = estimatedDataRate != nil ? String(format: "%.0f", estimatedDataRate! / 1000) + " kbps" : "unknown"

                        logDebug("[CURRENT QUALITY] Selected track: \(width)x\(height) @ \(bitrate)", context: "FullScreen")
                    } catch {
                        logWarning("Could not load selected track properties: \(error.localizedDescription)", context: "FullScreen")
                    }
                }
            }
        }

        // Also log all available video tracks for comparison
        for (index, track) in videoTracks.enumerated() {
            do {
                let naturalSize = try await track.load(.naturalSize)
                let estimatedDataRate = try? await track.load(.estimatedDataRate)

                let width = Int(naturalSize.width)
                let height = Int(naturalSize.height)
                let bitrate = estimatedDataRate != nil ? String(format: "%.0f", estimatedDataRate! / 1000) + " kbps" : "unknown"

                logDebug("Available track \(index): \(width)x\(height) @ \(bitrate)", context: "FullScreen")
            } catch {
                logWarning("Could not load track \(index) properties: \(error.localizedDescription)", context: "FullScreen")
            }
        }
    }

    // Logs access log entries which contain bitrate information
    private func logAccessLog(playerItem: AVPlayerItem) {
        guard let accessLog = playerItem.accessLog() else { return }

        if let lastEvent = accessLog.events.last {
            let uri = lastEvent.uri ?? "unknown"
            let indicatedBitrate = lastEvent.indicatedBitrate > 0 ? String(format: "%.0f", lastEvent.indicatedBitrate / 1000) + " kbps" : "unknown"
            let observedBitrate = lastEvent.observedBitrate > 0 ? String(format: "%.0f", lastEvent.observedBitrate / 1000) + " kbps" : "unknown"
            let switchCount = lastEvent.numberOfMediaRequests

            logDebug("[ACCESS LOG] URI: \(uri)", context: "FullScreen")
            logDebug("[ACCESS LOG] Indicated bitrate: \(indicatedBitrate), Observed: \(observedBitrate)", context: "FullScreen")
            logDebug("[ACCESS LOG] Switch count: \(switchCount), Duration: \(lastEvent.durationWatched)s", context: "FullScreen")
        }
    }
    
    // Starts periodic monitoring of video quality
    private func startQualityMonitoring(playerItem: AVPlayerItem) async {
        var iteration = 0
        while iteration < 30 { // Monitor for 60 seconds (30 iterations * 2 seconds)
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            await logCurrentVideoQuality(playerItem: playerItem)
            logAccessLog(playerItem: playerItem)
            iteration += 1
        }
        logDebug("Quality monitoring completed", context: "FullScreen")
    }
    
    deinit {
        loadTask?.cancel()
        qualityMonitoringTask?.cancel()
    }

    // Drops an in-flight original when the page goes away, so a photo
    // opened before the tailnet is up does not download after the user
    // has moved on.
    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }
}

#if DEBUG
// Lets dismiss tests install the production seek-resume wiring without a live
// stream so late play() callbacks can be asserted against teardown.
extension FullResolutionImageLoader {
    // Lets tests reproduce the dismiss-vs-seek-resume race without a live stream.
    func testingInstallDirectPlayResumeGate(
        player: AVPlayer,
        loader: DirectPlayResourceLoader,
        armResume: Bool
    ) {
        self.player = player
        self.directPlayLoader = loader
        wireDirectPlaySeekResume(on: loader, player: player, armResume: armResume)
    }
}
#endif

// Resolves the thumbnail manifest for one original so callers can share the
// same mapping logic across timeline and fullscreen preview surfaces.
func findMatchingThumbnail(
    for original: OriginalManifest,
    in thumbnailMap: [String: ThumbnailSetManifest]
) -> ThumbnailSetManifest? {
    let deviceSpace = original.metadata.deviceSpace
    let originalRef = "\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)"
    return thumbnailMap[originalRef]
}

// Picks the smallest thumbnail variant that satisfies a target display width
// so decoding work stays low without sacrificing sharpness.
func pickBestThumbnailEntry(
    from thumbnailSet: ThumbnailSetManifest,
    targetWidth: Int
) -> ThumbnailSetManifest.Spec.Entry? {
    let sorted = thumbnailSet.spec.thumbnails.sorted { $0.width < $1.width }
    return sorted.first(where: { $0.width >= targetWidth }) ?? sorted.last
}

@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    
    private let item: TimelineItem
    private let priority: ImageLoadPriority
    private weak var timelineManager: TimelineManager?
    private let onResolve: ((Bool) -> Void)?
    private var loadTask: Task<Void, Never>?
    private var didResolve = false
    
    // Creates one loader bound to a timeline item so cell lifecycle can observe resolved image state.
    init(
        item: TimelineItem,
        priority: ImageLoadPriority = .timelineViewport,
        timelineManager: TimelineManager,
        onResolve: ((Bool) -> Void)? = nil
    ) {
        self.item = item
        self.priority = priority
        self.timelineManager = timelineManager
        self.onResolve = onResolve
    }
    
    // Loads one thumbnail image while emitting fetch/decode/render milestones for Instruments.
    func loadImage() {
        guard image == nil && !isLoading else { return }
        
        // Check cache first for preloaded images
        if let cachedImage = timelineManager?.getCachedImage(for: item.id) {
            self.image = cachedImage
            AppSignposts.event("TimelineThumbnailCacheHit")
            resolveIfNeeded(didRenderImage: true)
            logDebug("Using cached image for \(item.id)", context: "Timeline")
            return
        }

        loadTask?.cancel()
        loadTask = Task {
            let loadSignpost = AppSignposts.begin("TimelineThumbnailLoad")
            defer {
                AppSignposts.end("TimelineThumbnailLoad", loadSignpost)
                isLoading = false
            }
            isLoading = true

            do {
                logDebug("Loading image for \(item.id)", context: "Timeline")

                // Reuse the repository and LFS client from TimelineManager
                guard let repository = timelineManager?.repository else {
                    logError("Repository not available in TimelineManager", context: "Timeline")
                    resolveIfNeeded(didRenderImage: false)
                    return
                }

                guard let lfsClient = timelineManager?.lfsClient else {
                    logError("LFS client not available in TimelineManager", context: "Timeline")
                    resolveIfNeeded(didRenderImage: false)
                    return
                }

                if let localImage = await loadLocalThumbnailIfAvailable() {
                    self.image = localImage
                    AppSignposts.event("TimelineThumbnailRendered")
                    timelineManager?.cacheImage(localImage, for: item.id)
                    resolveIfNeeded(didRenderImage: true)
                    logDebug("Loaded local Photo Library thumbnail for \(item.id)", context: "Timeline")
                    return
                }
                
                // Load thumbnail manifest on-demand when we need to display it
                let thumbnailSet = findMatchingThumbnail(
                    for: item.original,
                    in: timelineManager?.thumbnailMap ?? [:]
                )
                
                if let thumbnailSet = thumbnailSet,
                   let thumbnail = pickBestThumbnailEntry(from: thumbnailSet, targetWidth: 225) {
                    let deviceSpace = thumbnailSet.metadata.deviceSpace
                    let thumbnailPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(thumbnail.name))"
                    
                    let fetchSignpost = AppSignposts.begin("TimelineThumbnailFetchLFS")
                    let imageData = try await ImageDiskCacheManager.shared.loadImageData(
                        kind: .thumbnail,
                        priority: self.priority,
                        itemId: item.id,
                        lfsPath: thumbnailPath,
                        repository: repository,
                        lfsClient: lfsClient
                    )
                    AppSignposts.end("TimelineThumbnailFetchLFS", fetchSignpost)
                    
                    if Task.isCancelled {
                        resolveIfNeeded(didRenderImage: false)
                        return
                    }
                    
                    // Decode image off the main thread
                    let decodeSignpost = AppSignposts.begin("TimelineThumbnailDecode")
                    let loadedImage = await Task.detached(priority: .userInitiated) {
                        UIImage(data: imageData)
                    }.value
                    AppSignposts.end("TimelineThumbnailDecode", decodeSignpost)
                    
                    guard let loadedImage = loadedImage else {
                        logError("Failed to create UIImage from data for \(item.id)", context: "Timeline")
                        resolveIfNeeded(didRenderImage: false)
                        return
                    }

                    // Update UI on main thread
                    self.image = loadedImage
                    AppSignposts.event("TimelineThumbnailRendered")
                    // Store in cache for reuse
                    timelineManager?.cacheImage(loadedImage, for: item.id)
                    resolveIfNeeded(didRenderImage: true)
                    logDebug("Successfully loaded image for \(item.id)", context: "Timeline")
                } else {
                    logWarning("No thumbnail found for \(item.id)", context: "Timeline")
                    resolveIfNeeded(didRenderImage: false)
                }
            } catch is CancellationError {
                // Expected when cells are recycled; leave unresolved so a later configure can retry.
                return
            } catch {
                logError("Failed to load image for \(item.id): \(error.localizedDescription)", context: "Timeline")
                resolveIfNeeded(didRenderImage: false)
            }
        }
    }

    // Tries local Photos-based thumbnail lookup when enabled so timeline cells can avoid LFS network latency.
    // Returns nil when disabled, missing local identifiers, or unavailable local assets to preserve existing fallback flow.
    func loadLocalThumbnailIfAvailable(targetSize: CGSize = CGSize(width: 225, height: 225)) async -> UIImage? {
        guard CacheSettingsManager.shared.localThumbnailsEnabled else {
            return nil
        }

        guard let localID = item.original.spec.localID, !localID.isEmpty else {
            return nil
        }

        guard let photoLibrary = timelineManager?.photoLibrary else {
            return nil
        }

        guard photoLibrary.isAuthorized else {
            return nil
        }

        return await photoLibrary.generateThumbnail(forLocalIdentifier: localID, size: targetSize)
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }
    
    // Reports one terminal outcome so viewport hydration milestones resolve exactly once per loader.
    private func resolveIfNeeded(didRenderImage: Bool) {
        guard !didResolve else { return }
        didResolve = true
        onResolve?(didRenderImage)
    }
    
    deinit {
        loadTask?.cancel()
    }
}

#Preview("Empty") {
    TimelineView(previewState: .empty)
}

#Preview("Loading") {
    TimelineView(previewState: .loading)
}

#Preview("Error") {
    TimelineView(previewState: .error("LFS URL not configured"))
}
