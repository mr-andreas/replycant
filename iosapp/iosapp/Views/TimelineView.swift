import SwiftUI
import LibGit2
import AVKit
import UIKit
import Combine

// Shards media filenames into prefix directories so UI reads align with git tree fanout layout.
func shardName(_ name: String) -> String {
    if name.count < 5 {
        return name
    }
    let first = String(name.prefix(2))
    let second = String(name.dropFirst(2).prefix(2))
    let rest = String(name.dropFirst(4))
    return "\(first)/\(second)/\(rest)"
}

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
    @State private var selectedItem: SelectedTimelineItem?
    @State private var showMonthSidebar = false
    private let previewState: PreviewState?

    // Allows previews to render TimelineView states without repository and LFS dependencies.
    init(previewState: PreviewState? = nil) {
        self.previewState = previewState
        _timelineManager = StateObject(wrappedValue: TimelineManager())
    }

    var body: some View {
        // NavigationStack keeps timeline content in the primary column on iPad;
        // NavigationView would park it in a collapsed sidebar with an empty detail pane.
        NavigationStack {
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
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
                guard previewState == nil else { return }
                TimelineRenderMilestoneTracker.shared.resetForNewTimelineLoad()
                await timelineManager.loadTimeline(force: true)
            }
            .task {
                guard previewState == nil else { return }
                TimelineRenderMilestoneTracker.shared.resetForNewTimelineLoad()
                await timelineManager.loadTimeline()
            }
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
            
            Text("No photos uploaded yet")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Upload some photos to see them in your timeline")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
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
        .fullScreenCover(item: $selectedItem) { selected in
            FullScreenMediaView(initialItemId: selected.id, timelineManager: timelineManager)
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
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 1
        layout.minimumInteritemSpacing = 1
        layout.sectionInset = .zero

        let collectionView = InitialLayoutCollectionView(frame: .zero, collectionViewLayout: layout)
        AppSignposts.event("TimelineCollectionViewCreated")
        collectionView.backgroundColor = .systemBackground
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(TimelineCollectionCell.self, forCellWithReuseIdentifier: TimelineCollectionCell.reuseIdentifier)
        collectionView.onDidLayoutSubviews = { [weak coordinator = context.coordinator] in
            coordinator?.performInitialScrollIfNeeded()
        }
        collectionView.onBoundsWidthWillChange = { [weak coordinator = context.coordinator] in
            coordinator?.handleCollectionWidthWillChange()
        }
        collectionView.onBoundsWidthChanged = { [weak coordinator = context.coordinator] _ in
            coordinator?.handleCollectionWidthChange()
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
        private var isHandlingWidthChange = false
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
                    collectionView.reloadData()
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
                    let row = anchorIndex / 3
                    let side = max(1, (collectionView.bounds.width - 2) / 3.0)
                    restoredOffset.y = (CGFloat(row) * (side + 1)) + anchorOffset
                }
                collectionView.setContentOffset(restoredOffset, animated: false)
                collectionView.layoutIfNeeded()
                hasCommittedInitialPosition = true
                lastStableContentOffsetY = collectionView.contentOffset.y
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
            lastStableContentOffsetY = collectionView.contentOffset.y
            AppSignposts.event("TimelineGridFirstLayout")
        }

        func handleCollectionWidthWillChange() {
            guard let collectionView else { return }
            guard hasCommittedInitialPosition else { return }
            pendingWidthChangeAnchor = visibleTopAnchor(in: collectionView)
        }

        // Invalidates and re-anchors layout when collection width changes so sidebar toggles do not shift visible media.
        func handleCollectionWidthChange() {
            guard let collectionView else { return }
            guard hasCommittedInitialPosition else { return }
            guard !isHandlingWidthChange else { return }
            let persistedAnchor: (indexPath: IndexPath, offsetFromItemTop: CGFloat)? = {
                guard let index = timelineManager.savedViewportAnchorIndex,
                      let offset = timelineManager.savedViewportAnchorOffsetFromItemTop else {
                    return nil
                }
                return (IndexPath(item: index, section: 0), offset)
            }()
            let anchor = pendingWidthChangeAnchor ?? persistedAnchor ?? visibleTopAnchor(in: collectionView)
            pendingWidthChangeAnchor = nil
            isHandlingWidthChange = true
            defer { isHandlingWidthChange = false }
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if !restoreVisibleTopAnchor(anchor, in: collectionView),
               let lastStableContentOffsetY {
                setContentOffsetY(lastStableContentOffsetY, in: collectionView)
            }
            timelineManager.savedContentOffset = collectionView.contentOffset
            timelineManager.savedGridWidth = collectionView.bounds.width
            lastStableContentOffsetY = collectionView.contentOffset.y
        }

        // Updates persisted offset and active month with a low-cost visible-index lookup suitable for per-frame callbacks.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isHandlingWidthChange else { return }
            if hasCommittedInitialPosition {
                timelineManager.savedContentOffset = scrollView.contentOffset
                lastStableContentOffsetY = scrollView.contentOffset.y
            }
            guard let collectionView = scrollView as? UICollectionView else { return }
            timelineManager.savedGridWidth = collectionView.bounds.width
            guard !isProgrammaticMonthJumpInFlight else { return }
            let topIndex = topVisibleItemIndex(in: collectionView)
            if let topIndex,
               let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: topIndex, section: 0)) {
                timelineManager.savedViewportAnchorIndex = topIndex
                timelineManager.savedViewportAnchorOffsetFromItemTop = scrollView.contentOffset.y - attributes.frame.minY
            }
            guard topIndex != lastKnownTopVisibleIndex else { return }
            lastKnownTopVisibleIndex = topIndex
            timelineManager.updateCurrentMonth(for: topIndex)
        }

        // Flags dragging start so sidebar can avoid expensive animation during active grid interaction.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isProgrammaticMonthJumpInFlight = false
            timelineManager.setGridScrolling(true)
        }

        // Clears drag flag when user lifts finger and no deceleration remains.
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                timelineManager.setGridScrolling(false)
                flushPendingReconfigure()
            }
        }

        // Clears drag flag after inertial scrolling settles so sidebar may resume animated autoscroll.
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            timelineManager.setGridScrolling(false)
            flushPendingReconfigure()
        }

        // Clears drag flag after programmatic scroll animation finishes so sidebar can settle smoothly.
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticMonthJumpInFlight = false
            timelineManager.setGridScrolling(false)
            flushPendingReconfigure()
            if let collectionView = scrollView as? UICollectionView {
                let topIndex = topVisibleItemIndex(in: collectionView)
                lastKnownTopVisibleIndex = topIndex
                timelineManager.updateCurrentMonth(for: topIndex)
            }
        }

        // Scrolls the collection view to one target global index so month taps land at the top of the viewport.
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
            isProgrammaticMonthJumpInFlight = true
            collectionView.scrollToItem(at: indexPath, at: .top, animated: true)
            timelineManager.scrollTargetIndex = nil
        }

        // Finds the top visible global index using visible index paths to avoid expensive layout-attribute scans.
        private func topVisibleItemIndex(in collectionView: UICollectionView) -> Int? {
            return collectionView.indexPathsForVisibleItems.min(by: { lhs, rhs in
                lhs.item < rhs.item
            })?.item
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

        // Restores content offset from one saved anchor so the exact same media row stays in place after relayout.
        @discardableResult
        private func restoreVisibleTopAnchor(_ anchor: (indexPath: IndexPath, offsetFromItemTop: CGFloat)?, in collectionView: UICollectionView) -> Bool {
            guard let anchor else {
                return false
            }
            guard collectionView.numberOfItems(inSection: anchor.indexPath.section) > anchor.indexPath.item else {
                return false
            }
            let desiredY: CGFloat
            if let attributes = collectionView.layoutAttributesForItem(at: anchor.indexPath) {
                desiredY = attributes.frame.minY + anchor.offsetFromItemTop
            } else {
                let row = anchor.indexPath.item / 3
                let side = max(1, (collectionView.bounds.width - 2) / 3.0)
                desiredY = (CGFloat(row) * (side + 1)) + anchor.offsetFromItemTop
            }
            setContentOffsetY(desiredY, in: collectionView)
            return true
        }

        // Clamps one vertical offset to UIKit's scroll range so width-change anchor restoration stays valid.
        private func setContentOffsetY(_ y: CGFloat, in collectionView: UICollectionView) {
            let inset = collectionView.adjustedContentInset
            let minY = -inset.top
            let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
            let clampedY = min(max(y, minY), maxY)
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: clampedY), animated: false)
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

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            let totalSpacing: CGFloat = 2
            let side = max(1, (collectionView.bounds.width - totalSpacing) / 3.0)
            return CGSize(width: side, height: side)
        }
    }
}

final class InitialLayoutCollectionView: UICollectionView {
    var onDidLayoutSubviews: (() -> Void)?
    var onBoundsWidthWillChange: (() -> Void)?
    var onBoundsWidthChanged: ((CGFloat) -> Void)?
    private var lastKnownBoundsWidth: CGFloat = 0

    // Emits width changes so parent coordinator can invalidate flow layout after sidebar show/hide resizes the grid.
    override func layoutSubviews() {
        let widthChanged = abs(bounds.width - lastKnownBoundsWidth) > 0.5
        if widthChanged {
            onBoundsWidthWillChange?()
        }
        super.layoutSubviews()
        if widthChanged {
            lastKnownBoundsWidth = bounds.width
            onBoundsWidthChanged?(bounds.width)
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
// fullScreenCover and @Environment(\.dismiss).
struct FullScreenMediaView: View {
    let initialItemId: String
    @ObservedObject var timelineManager: TimelineManager
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
                            Text(mimeType)
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
    nonisolated static let playbackMIMETypeAssetOptionKey = "AVURLAssetOutOfBandMIMETypeKey"

    // Carries request-scoped playback values so backend decrypting services can stream plaintext without KEK access.
    private struct VideoPlaybackContext {
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

        let loadedImage = await Task.detached(priority: .userInitiated) {
            UIImage(data: mediaData)
        }.value

        guard let loadedImage else {
            throw FullResolutionImageLoadError.decodeFailed
        }
        return loadedImage
    }

    // Resolves full-resolution image bytes from local Photos when the performance toggle is enabled.
    // Returns nil to preserve fallback behavior when permission, identifiers, or local availability are missing.
    private static func loadLocalOriginalImageIfAvailable(
        for item: TimelineItem,
        photoLibrary: PhotoLibraryProviding?
    ) async -> UIImage? {
        guard CacheSettingsManager.shared.localThumbnailsEnabled else {
            return nil
        }
        guard let photoLibrary, photoLibrary.isAuthorized else {
            return nil
        }
        guard let localID = item.original.spec.localID, !localID.isEmpty else {
            return nil
        }
        guard let localData = await photoLibrary.getOriginalImageData(forLocalIdentifier: localID) else {
            return nil
        }

        let localImage = await Task.detached(priority: .userInitiated) {
            UIImage(data: localData)
        }.value
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

                    let loadedImage = try await Self.loadOriginalImage(
                        for: item,
                        priority: .fullscreenCurrent,
                        repository: repository,
                        lfsClient: lfsClient
                    )
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
        if let localPlayer = await makeLocalVideoPlayerIfAvailable(for: item) {
            self.player = localPlayer
            qualityMonitoringTask?.cancel()
            qualityMonitoringTask = nil
            directPlayLoader = nil
            hlsLoader = nil
            logDebug("Loaded local video asset for \(item.id)", context: "FullScreen")
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
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: playerItem,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    self.logAccessLog(playerItem: playerItem)
                }
            }
        }
        
        let avPlayer = AVPlayer(playerItem: playerItem)
        // Direct MP4 seeks need AVPlayer to preserve play intent while new
        // byte ranges buffer; HLS keeps the faster startup behavior.
        avPlayer.automaticallyWaitsToMinimizeStalling = !usesHLS
        if !usesHLS, let directPlayLoader = self.directPlayLoader {
            var seekResumeGate = DirectPlayResumeGate()

            directPlayLoader.onSeekRangeReplacementStarted = { [weak avPlayer] in
                guard let avPlayer else { return }
                let shouldPause = seekResumeGate.handleReplacementStarted(
                    isPlayingOrWaiting: avPlayer.rate > 0
                        || avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
                )
                if shouldPause {
                    avPlayer.pause()
                }
            }
            directPlayLoader.onSeekRangeReplacementReady = {
                if seekResumeGate.handleReplacementReady() {
                    Task { @MainActor in
                        avPlayer.play()
                    }
                }
            }
        }
        self.player = avPlayer
        logDebug("Successfully created \(modeDescription) player for video (LFS OID: \(objectIDForPlayback))", context: "FullScreen")
        logDebug("Player configured - automaticallyWaitsToMinimizeStalling: \(avPlayer.automaticallyWaitsToMinimizeStalling)", context: "FullScreen")
        qualityMonitoringTask?.cancel()
        qualityMonitoringTask = nil

        // Surfaces silent AVPlayerItem failures so direct-play issues are diagnosable from logs.
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { notification in
            Task { @MainActor in
                let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                logError("PlayerItem failed to play to end: \(err?.localizedDescription ?? "unknown")", context: "FullScreen")
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: playerItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if let errorLog = playerItem.errorLog(), let last = errorLog.events.last {
                    logError("[ERROR LOG] status=\(last.errorStatusCode) domain=\(last.errorDomain) comment=\(last.errorComment ?? "none") uri=\(last.uri ?? "none")", context: "FullScreen")
                }
            }
        }

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
    private static func resolveVideoPlaybackContext(item: TimelineItem, repository: Repository) throws -> VideoPlaybackContext {
        let deviceSpace = item.original.metadata.deviceSpace
        let pointerPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/Original/\(shardName(item.original.metadata.name))"
        let pointerContent = try repository.readFile(at: pointerPath)
        let pointer = try parseVideoPointer(pointerContent)
        guard let epoch = pointer.kekEpoch,
              let wrappedDEK = pointer.wrappedDEK else {
            throw LFSError.invalidEncryptionMetadata
        }

        let kek = try KEKEpochManager(repository: repository).loadKEK(epoch: epoch)
        guard let wrappedDEKData = Data(base64Encoded: wrappedDEK) else {
            throw LFSError.invalidEncryptionMetadata
        }
        let dek = try EncryptionUtils.unwrapDEK(wrappedDEKData, withKEK: kek, kekEpoch: epoch)
        let dekBase64 = dek.base64EncodedString()
        return VideoPlaybackContext(encryptedOID: pointer.oid, dekBase64: dekBase64)
    }

    // Parses pointer metadata required for decryptd-backed playback from the git working copy.
    private static func parseVideoPointer(_ pointerContent: String) throws -> LFSPointer {
        let lines = pointerContent.components(separatedBy: .newlines)
        var oid: String?
        var size: Int64?
        var kekEpoch: Int?
        var wrappedDEK: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("oid sha256:") {
                oid = String(trimmed.dropFirst("oid sha256:".count))
            } else if trimmed.hasPrefix("size ") {
                size = Int64(trimmed.dropFirst("size ".count))
            } else if trimmed.hasPrefix("x-replycant-kek-epoch ") {
                kekEpoch = Int(trimmed.dropFirst("x-replycant-kek-epoch ".count))
            } else if trimmed.hasPrefix("x-replycant-wrapped-dek ") {
                wrappedDEK = String(trimmed.dropFirst("x-replycant-wrapped-dek ".count))
            }
        }

        guard let oid,
              oid.count == 64,
              size != nil else {
            throw LFSError.invalidEncryptionMetadata
        }
        return LFSPointer(oid: oid, size: size ?? 0, kekEpoch: kekEpoch, wrappedDEK: wrappedDEK)
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
}

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
