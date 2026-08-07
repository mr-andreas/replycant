import Foundation
import LibGit2
import SwiftUI
import Combine
import GitDB
import os.signpost

// Represents a timeline item with original manifest and optional thumbnail
struct TimelineItem: Identifiable {
    let id: String
    let original: OriginalManifest
    let thumbnail: ThumbnailSetManifest?
    let sortDate: Date
    
    init(original: OriginalManifest, thumbnail: ThumbnailSetManifest? = nil) {
        self.id = original.spec.id
        self.original = original
        self.thumbnail = thumbnail
        
        // Timeline items only include originals with takenAt, so sortDate is always the capture time.
        self.sortDate = original.spec.takenAt!
    }
}

// Identifies one year/month bucket so timeline and sidebar can share one stable selection key.
struct TimelineYearMonth: Hashable {
    let year: Int
    let month: Int
}

// Describes one month section in the timeline index, including its global starting offset.
struct TimelineMonthEntry: Identifiable {
    let yearMonth: TimelineYearMonth
    let count: Int
    let globalOffset: Int

    var year: Int { yearMonth.year }
    var month: Int { yearMonth.month }
    var id: String { "\(yearMonth.year)-\(yearMonth.month)" }
}

// Isolates sidebar-specific state so month updates avoid invalidating the whole timeline view tree.
@MainActor
final class TimelineMonthSelectionModel: ObservableObject {
    @Published fileprivate(set) var sections: [TimelineMonthSidebarSection] = []
    @Published fileprivate(set) var currentYearMonth: TimelineYearMonth?
    @Published fileprivate(set) var isGridScrolling = false
}

// Coordinates sparse timeline loading, viewport preloading, and reactive database mutation handling.
@MainActor
final class TimelineManager: ObservableObject {
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    private(set) var loadGeneration = 0
    let loadGenerationPublisher = PassthroughSubject<Int, Never>()
    @Published private(set) var monthIndex: [TimelineMonthEntry] = []
    let monthSelection = TimelineMonthSelectionModel()
    @Published var scrollTargetIndex: Int?

    // Stores the most recent viewport index so month selection can be
    // flushed after dragging settles without relying on another scroll event.
    private var pendingMonthIndex: Int?
    // Limits month-publish frequency during high-rate scroll callbacks to
    // prevent sidebar updates from competing with interactive scrolling.
    private var lastMonthUpdateTime: Date = .distantPast
    private let monthUpdateInterval: TimeInterval = 0.5
    
    // Expose repository and lfsClient for reuse by image loaders
    private(set) var repository: Repository?
    private(set) var lfsClient: GitLFS?
    private(set) var photoLibrary: PhotoLibraryProviding
    
    // Maps original references to their corresponding thumbnails for efficient lookup
    // Key format: "{device-space}/media.replycant.com/v1alpha1/Original/{name}"
    private(set) var thumbnailMap: [String: ThumbnailSetManifest] = [:]
    
    // Manifest reader bound to the database-backed manifest manager.
    private var manifestLoader: ManifestLoaderProtocol?
    private var databaseChangeCancellable: AnyCancellable?

    // Keeps one contiguous loaded region so sparse grid reads can map global indices to loaded items.
    private var loadedOffset = 0
    private(set) var loadedItems: [TimelineItem] = []
    private var olderCursor: TimelineCursor?
    private var newerCursor: TimelineCursor?
    private var itemsById: [String: TimelineItem] = [:]
    private let pageSize = 100
    private var isLoadingPage = false
    
    // Tracks visible item indices for viewport-based preloading
    private var visibleIndices: Set<Int> = []
    
    // Tracks item IDs that should be preloaded based on viewport position
    private var preloadItemIds: Set<String> = []
    
    // Maintains ImageLoader instances for preloading items outside the viewport
    // Keyed by item ID to allow reuse when items become visible
    private var preloadImageLoaders: [String: ImageLoader] = [:]
    
    // LRU cache of loaded images keyed by item ID with memory-based eviction
    // Allows TimelineGridItem ImageLoaders to reuse preloaded images
    private lazy var imageCache: ImageCacheWrapper = {
        let cacheSettings = CacheSettingsManager.shared
        return ImageCacheWrapper(maxMemoryMB: cacheSettings.maxTimelineThumbnailRAMCacheSizeMB)
    }()
    
    // Stores Combine cancellables for preload image loader observations
    private var preloadCancellables: [String: AnyCancellable] = [:]
    
    // Observes cache settings changes to update cache size limit
    private var cacheSettingsObserver: AnyCancellable?
    // Observes LFS endpoint updates so timeline loaders rebuild clients against the new server.
    private var lfsURLObserver: AnyCancellable?
    // Observes replacement of the shared manifest database so cached handles are rebound.
    private var databaseInvalidationObserver: AnyCancellable?
    // Reload driven by database replacement, retained so a newer reset supersedes it.
    private var databaseReloadTask: Task<Void, Never>?
    // Spans a reset's rebuild without retrying long enough to hide a real failure.
    private static let databaseReloadAttempts = 10
    private static let databaseReloadRetryDelayNanoseconds: UInt64 = 1_000_000_000
    // Source of endpoint-change broadcasts.
    private let notificationCenter: NotificationCenter

    // Debounced tasks that warm disk caches with the newest
    // thumbnails so the first screen and recent browsing are
    // fast even after a cold start.
    private var warmTopTask: Task<Void, Never>?
    private var warmMainTask: Task<Void, Never>?

    // Injects photo library access so timeline thumbnail loaders can use local-device assets before LFS fallback.
    // The notification center is injectable so a test can subscribe to an
    // isolated center. Endpoint-change broadcasts are process-wide, so an
    // unrelated suite repointing the server would otherwise wipe this
    // manager's loaded region and month selection mid-test.
    init(
        photoLibrary: PhotoLibraryProviding = PhotoLibraryManager(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.photoLibrary = photoLibrary
        self.notificationCenter = notificationCenter
        observeLFSURLChanges()
        observeDatabaseInvalidation()
    }

    // Exposes sidebar sections through manager API while keeping publish scope isolated to monthSelection.
    var monthSidebarSections: [TimelineMonthSidebarSection] {
        monthSelection.sections
    }

    // Exposes selected month through manager API while keeping publish scope isolated to monthSelection.
    var currentYearMonth: TimelineYearMonth? {
        monthSelection.currentYearMonth
    }

    // Exposes grid-scrolling state through manager API while keeping publish scope isolated to monthSelection.
    var isGridScrolling: Bool {
        monthSelection.isGridScrolling
    }

    // Persists the collection view content offset so the scroll position survives UIViewRepresentable remounts.
    var savedContentOffset: CGPoint?
    var savedViewportAnchorIndex: Int?
    var savedViewportAnchorOffsetFromItemTop: CGFloat?
    var savedGridWidth: CGFloat?

    // Loads repository dependencies and timeline count while deferring item hydration to sparse on-demand fetches.
    // Skips redundant work when the timeline is already loaded unless force is true (pull-to-refresh).
    func loadTimeline(force: Bool = false) async {
        if !force && repository != nil && totalCount > 0 {
            return
        }

        let loadTimelineSignpost = AppSignposts.begin("TimelineLoadMetadata")
        defer {
            AppSignposts.end("TimelineLoadMetadata", loadTimelineSignpost)
        }

        if force {
            savedContentOffset = nil
            savedViewportAnchorIndex = nil
            savedViewportAnchorOffsetFromItemTop = nil
            savedGridWidth = nil
        }

        let timelineStartTime = CFAbsoluteTimeGetCurrent()
        log("Starting timeline load...", context: "Timeline")
        isLoading = true
        errorMessage = nil
        
        // Initialize cache with current settings
        let cacheSettings = CacheSettingsManager.shared
        imageCache.setMaxMemoryMB(cacheSettings.maxTimelineThumbnailRAMCacheSizeMB)
        
        // Observe cache size changes
        setupCacheSettingsObserver()
        
        do {
            log("Checking repository at: \(RepositoryManager.shared.repositoryPath())", context: "Timeline")
            
            guard let lfsUrl = ServerConfigurationManager.shared.loadLFSURL(), !lfsUrl.isEmpty else {
                logError("LFS URL not configured", context: "Timeline")
                logError("Please configure LFS URL in settings first", context: "Timeline")
                throw TimelineError.lfsUrlNotConfigured
            }
            
            do {
                let repositoryOpenSignpost = AppSignposts.begin("TimelineOpenRepository")
                defer {
                    AppSignposts.end("TimelineOpenRepository", repositoryOpenSignpost)
                }
                repository = try RepositoryManager.shared.getRepository()
            } catch {
                logError("Repository not found at: \(RepositoryManager.shared.repositoryPath())", context: "Timeline")
                logError("Please upload some photos first using the Upload tab", context: "Timeline")
                throw TimelineError.repositoryNotFound
            }
            
            log("Using LFS server: \(lfsUrl)", context: "Timeline")
            lfsClient = GitLFS(
                serverURL: lfsUrl,
                clientIdentity: ClientIdentityManager.shared.loadSecIdentity(),
                pinnedCA: ServerConfigurationManager.shared.loadSecCertificate()
            )
            
            // Initializes database-backed loader so timeline reads use the shared SQL cache.
            let getDatabaseSignpost = AppSignposts.begin("TimelineGetManifestDatabase")
            let database: ManifestDatabase
            do {
                defer {
                    AppSignposts.end("TimelineGetManifestDatabase", getDatabaseSignpost)
                }
                database = try ManifestLoaderManager.shared.getDatabase()
            } catch {
                throw error
            }
            let registry = ManifestLoaderManager.shared.getRegistry()
            let manifestManager = DefaultManifestManager(
                repository: repository!,
                deviceSpace: DeviceIdentifierManager.shared.deviceSpaceIdentifier,
                lfsClient: lfsClient!,
                database: database,
                registry: registry
            )
            manifestLoader = manifestManager

            // Subscribes once so timeline state reacts to sync/upload/delete writes without polling.
            databaseChangeCancellable?.cancel()
            databaseChangeCancellable = database.changes
                .receive(on: DispatchQueue.main)
                .sink { [weak self] change in
                    Task { @MainActor in
                        await self?.handleDatabaseChange(change)
                    }
                }

            resetLoadedRegion(clearVisibleIndices: true)
            let countSignpost = AppSignposts.begin("TimelineCountItems")
            do {
                defer {
                    AppSignposts.end("TimelineCountItems", countSignpost)
                }
                totalCount = try await manifestManager.countTimelineOriginals()
                updateMonthIndex(try await buildMonthIndex(loader: manifestManager))
            } catch {
                throw error
            }
            if totalCount > 0 {
                let initialRegionSignpost = AppSignposts.begin("TimelineInitialRegionLoad")
                await ensureLoaded(around: totalCount - 1)
                AppSignposts.end("TimelineInitialRegionLoad", initialRegionSignpost)
            } else {
                monthSelection.currentYearMonth = nil
            }
            scheduleDiskCacheWarming()

            let timelineEndTime = CFAbsoluteTimeGetCurrent()
            let timelineDuration = timelineEndTime - timelineStartTime
            log("Timeline metadata loaded with \(totalCount) items in \(String(format: "%.3f", timelineDuration)) seconds", context: "Timeline")
            AppSignposts.event("TimelineMetadataReady")
            
        } catch {
            let timelineEndTime = CFAbsoluteTimeGetCurrent()
            let timelineDuration = timelineEndTime - timelineStartTime
            logError("Failed to load timeline after \(String(format: "%.3f", timelineDuration)) seconds: \(error.localizedDescription)", context: "Timeline")
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }

    // Returns one loaded timeline item when the requested global index is currently present in memory.
    func item(at index: Int) -> TimelineItem? {
        guard index >= loadedOffset, index < loadedOffset + loadedItems.count else {
            return nil
        }
        return loadedItems[index - loadedOffset]
    }

    var canLoadOlder: Bool {
        loadedOffset > 0
    }

    var canLoadNewer: Bool {
        loadedOffset + loadedItems.count < totalCount
    }

    // Resolves and emits the month currently at the top of the viewport while
    // rate-limiting updates so sidebar rendering does not hurt scroll smoothness.
    func updateCurrentMonth(for index: Int?, force: Bool = false) {
        pendingMonthIndex = index
        guard let index else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastMonthUpdateTime) < monthUpdateInterval {
            return
        }
        guard let item = item(at: index), let date = item.original.spec.takenAt else { return }
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return }
        let nextMonth = TimelineYearMonth(year: year, month: month)
        guard currentYearMonth != nextMonth else { return }
        lastMonthUpdateTime = now
        monthSelection.currentYearMonth = nextMonth
    }

    // Requests a sparse jump to the first item in a month so tapping the sidebar lands at that month's first row.
    func scrollToMonth(year: Int, month: Int) {
        guard let entry = monthIndex.first(where: { $0.year == year && $0.month == month }) else { return }
        let targetMonth = TimelineYearMonth(year: year, month: month)
        monthSelection.currentYearMonth = targetMonth
        let targetIndex = max(0, min(totalCount - 1, entry.globalOffset))
        Task { @MainActor in
            await ensureLoaded(around: targetIndex)
            monthSelection.currentYearMonth = targetMonth
            scrollTargetIndex = targetIndex
        }
    }

    /// Tracks active grid scrolling state so sidebar animations and
    /// preload work can be suppressed during drag/deceleration. When
    /// scrolling ends, fires the pending preload pass immediately so
    /// off-screen images begin loading without the 150ms debounce delay.
    func setGridScrolling(_ isScrolling: Bool) {
        guard isGridScrolling != isScrolling else { return }
        monthSelection.isGridScrolling = isScrolling
        if !isScrolling {
            updateCurrentMonth(for: pendingMonthIndex, force: true)
            preloadUpdateWorkItem?.cancel()
            preloadUpdateWorkItem = nil
            updatePreloadRange()
        }
    }

    // Ensures data for one global index by extending the loaded region or cold-jumping to a new offset.
    func ensureLoaded(around index: Int) async {
        guard index >= 0, index < totalCount else { return }
        guard let manifestLoader else { return }

        if item(at: index) != nil {
            return
        }
        guard !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            if loadedItems.isEmpty {
                let adjustedOffset = max(0, index - pageSize / 2)
                try await loadFreshRegion(offset: adjustedOffset, loader: manifestLoader)
                return
            }

            let regionStart = loadedOffset
            let regionEnd = loadedOffset + loadedItems.count - 1
            let distanceToOlderEdge = regionStart - index
            let distanceToNewerEdge = index - regionEnd

            if distanceToOlderEdge > 0, distanceToOlderEdge <= pageSize, let olderCursor {
                let originals = try await manifestLoader.loadTimelinePage(before: olderCursor, limit: pageSize)
                try await prepend(originals: originals, loader: manifestLoader)
                return
            }

            if distanceToNewerEdge > 0, distanceToNewerEdge <= pageSize, let newerCursor {
                let originals = try await manifestLoader.loadTimelinePage(after: newerCursor, limit: pageSize)
                try await append(originals: originals, loader: manifestLoader)
                return
            }

            // Resets sparse state for random-access jumps so one contiguous region remains authoritative.
            resetLoadedRegion(clearVisibleIndices: false, clearCurrentMonth: false)
            let adjustedOffset = max(0, index - pageSize / 2)
            try await loadFreshRegion(offset: adjustedOffset, loader: manifestLoader)
        } catch {
            errorMessage = error.localizedDescription
            logError("Failed to ensure sparse load near \(index): \(error.localizedDescription)", context: "Timeline")
        }
    }

    // Ensures a swipe window around the full-screen index to keep paging smooth at loaded edges.
    func ensureWindowLoaded(around index: Int, radius: Int = 30) async {
        await ensureLoaded(around: index)
        let start = max(0, index - radius)
        let end = min(totalCount - 1, index + radius)
        for probe in [start, end] {
            if item(at: probe) == nil {
                await ensureLoaded(around: probe)
            }
        }
    }

    func loadOlderPage() async {
        guard !isLoadingPage else { return }
        guard let manifestLoader, let olderCursor, canLoadOlder else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        do {
            let originals = try await manifestLoader.loadTimelinePage(before: olderCursor, limit: pageSize)
            try await prepend(originals: originals, loader: manifestLoader)
        } catch {
            errorMessage = error.localizedDescription
            logError("Failed to load older timeline page: \(error.localizedDescription)", context: "Timeline")
        }
    }

    func loadNewerPage() async {
        guard !isLoadingPage else { return }
        guard let manifestLoader, let newerCursor, canLoadNewer else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        do {
            let originals = try await manifestLoader.loadTimelinePage(after: newerCursor, limit: pageSize)
            try await append(originals: originals, loader: manifestLoader)
        } catch {
            errorMessage = error.localizedDescription
            logError("Failed to load newer timeline page: \(error.localizedDescription)", context: "Timeline")
        }
    }
    
    private var pendingPagingIndices: Set<Int> = []
    private var pagingTask: Task<Void, Never>?

    /// Batches multiple willDisplay paging requests into a single task
    /// that runs after one frame (~16ms). During fast scrolling, dozens
    /// of cells call this per frame; coalescing avoids spawning one
    /// Task per cell through the main-actor executor.
    func schedulePagingIfNeeded(around index: Int, edgeThreshold: Int) {
        pendingPagingIndices.insert(index)
        guard pagingTask == nil else { return }
        pagingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self else { return }
            let indices = self.pendingPagingIndices
            self.pendingPagingIndices.removeAll()
            self.pagingTask = nil

            guard let target = indices.max() ?? indices.first else { return }
            await self.ensureLoaded(around: target)

            if self.item(at: max(0, target - edgeThreshold)) == nil,
               self.canLoadOlder {
                await self.loadOlderPage()
            }
            if self.item(at: min(max(0, self.totalCount - 1), target + edgeThreshold)) == nil,
               self.canLoadNewer {
                await self.loadNewerPage()
            }
        }
    }

    // Called when a TimelineGridItem appears in the viewport.
    // Updates visible indices and schedules a coalesced preload pass.
    func itemDidAppear(at index: Int) {
        visibleIndices.insert(index)
        schedulePreloadUpdate()
    }
    
    // Called when a TimelineGridItem disappears from the viewport.
    // Updates visible indices and schedules a coalesced preload pass.
    func itemDidDisappear(at index: Int) {
        visibleIndices.remove(index)
        schedulePreloadUpdate()
    }

    private var preloadUpdateWorkItem: DispatchWorkItem?

    /// Coalesces rapid appear/disappear calls into a single preload
    /// pass. During fast scrolling dozens of cells cycle per frame;
    /// deferring the O(200) preload iteration to a 150ms trailing
    /// edge eliminates per-cell main-thread work. Skipped entirely
    /// while the grid is actively scrolling — the preload fires
    /// immediately when scrolling settles via setGridScrolling(false).
    private func schedulePreloadUpdate() {
        guard !isGridScrolling else { return }
        preloadUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updatePreloadRange()
        }
        preloadUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    
    // Checks if an item should be preloaded based on current viewport position.
    // Used by TimelineGridItem to determine if it should load its image even when not visible.
    func shouldPreloadItem(at index: Int) -> Bool {
        guard totalCount > 0, index >= 0, index < totalCount, let item = item(at: index) else {
            return false
        }

        return preloadItemIds.contains(item.id)
    }
    
    // Calculates which items should be preloaded based on visible range and cache settings.
    // Updates preloadItemIds and triggers image loading for items in the preload range.
    private func updatePreloadRange() {
        guard !visibleIndices.isEmpty, totalCount > 0 else {
            preloadItemIds = []
            // Clean up preload loaders when nothing is visible
            preloadImageLoaders.removeAll()
            preloadCancellables.removeAll()
            return
        }

        let sortedIndices = visibleIndices.sorted()
        let firstVisible = sortedIndices.first!
        let lastVisible = sortedIndices.last!
        
        let cacheSettings = CacheSettingsManager.shared
        let beforeCount = cacheSettings.imagesBeforeViewport
        let afterCount = cacheSettings.imagesAfterViewport
        
        // Calculate preload range: [firstVisible - beforeCount, lastVisible + afterCount]
        let preloadStart = max(0, firstVisible - beforeCount)
        let preloadEnd = min(totalCount, lastVisible + 1 + afterCount)
        
        // Build set of item IDs that should be preloaded
        var newPreloadIds = Set<String>()
        for index in preloadStart..<preloadEnd {
            if let item = item(at: index) {
                newPreloadIds.insert(item.id)
            }
        }
        
        // Cancel and remove preload loaders for items no longer in range
        // so in-flight LFS work releases concurrency slots promptly.
        let itemsToRemove = preloadItemIds.subtracting(newPreloadIds)
        for itemId in itemsToRemove {
            preloadImageLoaders.removeValue(forKey: itemId)?.cancelLoading()
            preloadCancellables.removeValue(forKey: itemId)?.cancel()
        }
        
        // Create loaders and trigger loading for items in preload range that aren't visible
        for index in preloadStart..<preloadEnd {
            guard let item = item(at: index) else { continue }
            let itemId = item.id
            
            // Skip if already visible (will be loaded by TimelineGridItem)
            if visibleIndices.contains(index) {
                continue
            }
            
            // Skip if already cached
            if imageCache.get(for: itemId) != nil {
                continue
            }
            
            // Create loader if it doesn't exist
            if preloadImageLoaders[itemId] == nil {
                let loader = ImageLoader(
                    item: item,
                    priority: .timelinePage,
                    timelineManager: self
                )
                preloadImageLoaders[itemId] = loader
                // Observe loader's image to cache it when loaded
                let cancellable = loader.$image
                    .compactMap { $0 }
                    .sink { [weak self] loadedImage in
                        self?.cacheImage(loadedImage, for: itemId)
                    }
                preloadCancellables[itemId] = cancellable
                loader.loadImage()
            }
        }
        
        preloadItemIds = newPreloadIds
    }
    
    // Gets a cached image for an item if it was preloaded, or returns nil.
    // Allows TimelineGridItem ImageLoaders to reuse preloaded images instead of loading again.
    func getCachedImage(for itemId: String) -> UIImage? {
        return imageCache.get(for: itemId)
    }
    
    // Stores an image in the cache for reuse by TimelineGridItem ImageLoaders.
    // Called by preload ImageLoaders when they successfully load an image.
    func cacheImage(_ image: UIImage, for itemId: String) {
        imageCache.set(image, for: itemId)
    }
    
    // Sets up observation of cache settings changes to update cache size limit dynamically.
    private func setupCacheSettingsObserver() {
        cacheSettingsObserver = NotificationCenter.default.publisher(for: .cacheSettingsDidChange)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let cacheSettings = CacheSettingsManager.shared
                self.imageCache.setMaxMemoryMB(cacheSettings.maxTimelineThumbnailRAMCacheSizeMB)
            }
    }

    // Subscribes to LFS URL updates so timeline reloads immediately after repository settings repoints media traffic.
    private func observeLFSURLChanges() {
        lfsURLObserver = notificationCenter.publisher(for: ServerConfigurationManager.lfsURLDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleLFSURLDidChange()
            }
    }

    // Subscribes to replacement of the shared manifest database so a reset does
    // not strand this manager on a discarded instance. The subscription is set
    // up at init rather than during the first load, because a reset can land
    // before the timeline has ever loaded and the broadcast is not replayed.
    private func observeDatabaseInvalidation() {
        databaseInvalidationObserver = notificationCenter
            .publisher(for: ManifestLoaderManager.databaseDidInvalidateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDatabaseDidInvalidate()
            }
    }

    // Rebinds after the backing database is replaced. The previous count
    // described rows that are now unreachable, so it is dropped up front rather
    // than left to render placeholders for items the grid can never fetch.
    private func handleDatabaseDidInvalidate() {
        totalCount = 0
        discardCachedDependencies()
        retryReloadUntilDatabaseIsUsable()
    }

    // Reloads until the replacement database can actually be read.
    //
    // A reset deletes the database and rebuilds it immediately afterwards, so
    // this reload races that rebuild and SQLite reports the overlap as a
    // transient error rather than a missing file. Attempting once would leave
    // the timeline on an error screen until the app restarts, which is exactly
    // how a rebuild that briefly returned "disk I/O error" produced a blank
    // timeline. The budget is bounded so a genuinely unusable database still
    // surfaces to the user instead of retrying forever.
    private func retryReloadUntilDatabaseIsUsable() {
        databaseReloadTask?.cancel()
        databaseReloadTask = Task { [weak self] in
            for attempt in 0..<Self.databaseReloadAttempts {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: Self.databaseReloadRetryDelayNanoseconds)
                }
                guard let self, !Task.isCancelled else { return }
                await self.loadTimeline(force: true)
                if self.errorMessage == nil {
                    return
                }
            }
        }
    }

    // Clears cached LFS dependencies and triggers a forced timeline reload so current sessions switch endpoints immediately.
    private func handleLFSURLDidChange() {
        discardCachedDependencies()
        Task { [weak self] in
            await self?.loadTimeline(force: true)
        }
    }

    // Drops every handle derived from the repository, LFS endpoint, or manifest
    // database. Shared by endpoint changes and database replacement because
    // both leave the same set of cached objects stale, including the change
    // subscription bound to the old database instance.
    private func discardCachedDependencies() {
        lfsClient = nil
        manifestLoader = nil
        repository = nil
        databaseChangeCancellable?.cancel()
        databaseChangeCancellable = nil
        resetLoadedRegion(clearVisibleIndices: false)
    }

    // Applies database change events to sparse timeline state so UI updates without full reloads.
    private func handleDatabaseChange(_ change: ManifestDatabaseChange) async {
        guard let manifestLoader else {
            applyDatabaseChange(change, refreshedTotalCount: 0)
            return
        }
        do {
            let refreshedTotalCount = try await manifestLoader.countTimelineOriginals()
            applyDatabaseChange(change, refreshedTotalCount: refreshedTotalCount)
            updateMonthIndex(try await buildMonthIndex(loader: manifestLoader))
            if refreshedTotalCount == 0 {
                monthSelection.currentYearMonth = nil
            }
            scheduleDiskCacheWarming()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Applies one database change using a caller-provided count so production and tests share identical mutation logic.
    func applyDatabaseChange(_ change: ManifestDatabaseChange, refreshedTotalCount: Int) {
        switch change {
        case .fullReplace:
            resetLoadedRegion(clearVisibleIndices: true)
            totalCount = refreshedTotalCount
        case .incremental(let mutation):
            applyIncrementalMutation(mutation, refreshedTotalCount: refreshedTotalCount)
        }
    }

    // Merges incremental mutation payloads into currently loaded sparse state to avoid placeholder flashes.
    private func applyIncrementalMutation(_ mutation: ManifestMutation, refreshedTotalCount: Int) {
        totalCount = refreshedTotalCount
        visibleIndices = visibleIndices.filter { $0 >= 0 && $0 < refreshedTotalCount }
        let loadedItemIds = Set(loadedItems.map(\.id))
        let loadedOriginalRefs = Set(loadedItems.map { originalRef(for: $0.original) })
        var shouldReconfigureVisibleCells = false

        let addedOriginals = mutation.added.compactMap { $0 as? OriginalManifest }
            .filter { $0.spec.takenAt != nil }
        let removedOriginals = mutation.removed.compactMap { $0 as? OriginalManifest }
            .filter { $0.spec.takenAt != nil }
        let removedOriginalIds = Set(removedOriginals.map(\.id))

        let updatedOriginals = mutation.updated.compactMap { $0 as? OriginalManifest }
        let updatedOriginalsById = Dictionary(uniqueKeysWithValues: updatedOriginals.map { ($0.id, $0) })

        let updatedThumbnails = mutation.updated.compactMap { $0 as? ThumbnailSetManifest }
        let addedThumbnails = mutation.added.compactMap { $0 as? ThumbnailSetManifest }
        for thumbnail in updatedThumbnails + addedThumbnails {
            thumbnailMap[thumbnail.spec.originalRef] = thumbnail
            if loadedOriginalRefs.contains(thumbnail.spec.originalRef) {
                shouldReconfigureVisibleCells = true
            }
        }

        let previousOffset = loadedOffset
        var addedOriginalsWithinWindow: [OriginalManifest] = []
        if let firstLoaded = loadedItems.first?.original,
           let firstLoadedDate = firstLoaded.spec.takenAt {
            let firstLoadedKey = (firstLoadedDate, firstLoaded.id)
            let addedBeforeWindow = addedOriginals.filter {
                guard let date = $0.spec.takenAt else { return false }
                return (date, $0.id) < firstLoadedKey
            }.count
            loadedOffset += addedBeforeWindow

            if let lastLoaded = loadedItems.last?.original,
               let lastLoadedDate = lastLoaded.spec.takenAt {
                let lastLoadedKey = (lastLoadedDate, lastLoaded.id)
                addedOriginalsWithinWindow = addedOriginals.filter {
                    guard let date = $0.spec.takenAt else { return false }
                    let key = (date, $0.id)
                    return key >= firstLoadedKey && key <= lastLoadedKey
                }
            }

            let removedBeforeWindow = removedOriginals.filter {
                guard let date = $0.spec.takenAt else { return false }
                return (date, $0.id) < firstLoadedKey
            }.count
            loadedOffset = max(0, loadedOffset - removedBeforeWindow)
        }
        if loadedOffset != previousOffset {
            shouldReconfigureVisibleCells = true
        }

        if !removedOriginalIds.isEmpty {
            loadedItems.removeAll { removedOriginalIds.contains($0.id) }
            if !removedOriginalIds.isDisjoint(with: loadedItemIds) {
                shouldReconfigureVisibleCells = true
            }
            for removedId in removedOriginalIds {
                itemsById.removeValue(forKey: removedId)
                preloadItemIds.remove(removedId)
                preloadImageLoaders.removeValue(forKey: removedId)
                preloadCancellables.removeValue(forKey: removedId)
            }
        }

        if !addedOriginalsWithinWindow.isEmpty {
            let insertedItems = addedOriginalsWithinWindow
                .filter { itemsById[$0.id] == nil && !removedOriginalIds.contains($0.id) }
                .map { original in
                    TimelineItem(
                        original: original,
                        thumbnail: thumbnailMap[originalRef(for: original)]
                    )
                }
            if !insertedItems.isEmpty {
                loadedItems.append(contentsOf: insertedItems)
                loadedItems.sort { lhs, rhs in
                    guard
                        let lhsDate = lhs.original.spec.takenAt,
                        let rhsDate = rhs.original.spec.takenAt
                    else {
                        return lhs.id < rhs.id
                    }
                    if lhsDate != rhsDate {
                        return lhsDate < rhsDate
                    }
                    return lhs.id < rhs.id
                }
                shouldReconfigureVisibleCells = true
            }
        }

        if !updatedOriginalsById.isEmpty {
            for (index, existingItem) in loadedItems.enumerated() {
                guard let updatedOriginal = updatedOriginalsById[existingItem.id] else { continue }
                shouldReconfigureVisibleCells = true
                loadedItems[index] = TimelineItem(
                    original: updatedOriginal,
                    thumbnail: thumbnailMap[originalRef(for: updatedOriginal)]
                )
            }
        }

        for index in loadedItems.indices {
            let item = loadedItems[index]
            let ref = originalRef(for: item.original)
            guard let updatedThumbnail = thumbnailMap[ref] else { continue }
            guard item.thumbnail?.id != updatedThumbnail.id || item.thumbnail?.spec.thumbnails != updatedThumbnail.spec.thumbnails else { continue }
            shouldReconfigureVisibleCells = true
            loadedItems[index] = TimelineItem(original: item.original, thumbnail: updatedThumbnail)
        }

        rebuildItemIndex()
        updateRegionCursors()
        if shouldReconfigureVisibleCells {
            incrementLoadGeneration()
        }
    }

    // Seeds sparse region state for focused unit tests without requiring repository or database wiring.
    func seedLoadedRegionForTesting(offset: Int, items: [TimelineItem], totalCount: Int) {
        loadedOffset = offset
        loadedItems = items
        self.totalCount = totalCount
        thumbnailMap = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let thumbnail = item.thumbnail else { return nil }
            return (thumbnail.spec.originalRef, thumbnail)
        })
        preloadItemIds.removeAll()
        preloadImageLoaders.removeAll()
        preloadCancellables.removeAll()
        rebuildItemIndex()
        updateRegionCursors()
    }

    // Resets loaded items/cursors/caches so sparse state can be rebuilt from a new jump position.
    private func resetLoadedRegion(clearVisibleIndices: Bool, clearCurrentMonth: Bool = true) {
        loadedOffset = 0
        loadedItems = []
        olderCursor = nil
        newerCursor = nil
        if clearCurrentMonth {
            monthSelection.currentYearMonth = nil
        }
        itemsById.removeAll()
        thumbnailMap.removeAll()
        preloadItemIds.removeAll()
        preloadImageLoaders.removeAll()
        preloadCancellables.removeAll()
        if clearVisibleIndices {
            visibleIndices.removeAll()
        }
    }

    // Loads one fresh region from offset after clearing old sparse state during random access.
    private func loadFreshRegion(offset: Int, loader: ManifestLoaderProtocol) async throws {
        let signpostLog = OSLog(subsystem: "com.replycant.iosapp", category: "PointsOfInterest")
        let freshRegionSignpostId = OSSignpostID(log: signpostLog)
        var loadTimelinePageMs = 0.0
        os_signpost(
            .begin,
            log: signpostLog,
            name: "TimelineLoadFreshRegion",
            signpostID: freshRegionSignpostId,
            "offset=%{public}d",
            offset
        )
        defer {
            os_signpost(
                .end,
                log: signpostLog,
                name: "TimelineLoadFreshRegion",
                signpostID: freshRegionSignpostId,
                "loadTimelinePageMs=%{public}.2f",
                loadTimelinePageMs
            )
        }

        let pageLoadStart = DispatchTime.now().uptimeNanoseconds
        let originals: [OriginalManifest]
        do {
            originals = try await loader.loadTimelinePage(offset: offset, limit: pageSize)
        } catch {
            let pageLoadEnd = DispatchTime.now().uptimeNanoseconds
            loadTimelinePageMs = Double(pageLoadEnd - pageLoadStart) / 1_000_000
            throw error
        }
        let pageLoadEnd = DispatchTime.now().uptimeNanoseconds
        loadTimelinePageMs = Double(pageLoadEnd - pageLoadStart) / 1_000_000
        let refs = originals.map { originalRef(for: $0) }
        let thumbnails = try await loader.loadThumbnailsByOriginalRefs(refs)
        thumbnailMap.merge(thumbnails) { _, new in new }
        loadedOffset = offset
        loadedItems = originals.map { original in
            TimelineItem(original: original, thumbnail: thumbnailMap[originalRef(for: original)])
        }
        rebuildItemIndex()
        updateRegionCursors()
        incrementLoadGeneration()
    }

    // Prepends older originals to maintain one contiguous region while extending backward.
    private func prepend(originals: [OriginalManifest], loader: ManifestLoaderProtocol) async throws {
        guard !originals.isEmpty else { return }
        let prependSignpost = AppSignposts.begin("TimelinePrependRegion")
        defer {
            AppSignposts.end("TimelinePrependRegion", prependSignpost)
        }

        let refs = originals.map { originalRef(for: $0) }
        let thumbnails = try await loader.loadThumbnailsByOriginalRefs(refs)
        thumbnailMap.merge(thumbnails) { _, new in new }
        let newItems = originals.map { TimelineItem(original: $0, thumbnail: thumbnailMap[originalRef(for: $0)]) }
        loadedItems.insert(contentsOf: newItems, at: 0)
        loadedOffset = max(0, loadedOffset - newItems.count)
        for item in newItems {
            itemsById[item.id] = item
        }
        updateRegionCursors()
        incrementLoadGeneration()
    }

    // Appends newer originals to maintain one contiguous region while extending forward.
    private func append(originals: [OriginalManifest], loader: ManifestLoaderProtocol) async throws {
        guard !originals.isEmpty else { return }
        let appendSignpost = AppSignposts.begin("TimelineAppendRegion")
        defer {
            AppSignposts.end("TimelineAppendRegion", appendSignpost)
        }

        let refs = originals.map { originalRef(for: $0) }
        let thumbnails = try await loader.loadThumbnailsByOriginalRefs(refs)
        thumbnailMap.merge(thumbnails) { _, new in new }
        let newItems = originals.map { TimelineItem(original: $0, thumbnail: thumbnailMap[originalRef(for: $0)]) }
        loadedItems.append(contentsOf: newItems)
        for item in newItems {
            itemsById[item.id] = item
        }
        updateRegionCursors()
        incrementLoadGeneration()
    }

    // Rebuilds id lookup after region replacement so mutation handlers can resolve loaded membership quickly.
    private func rebuildItemIndex() {
        itemsById = Dictionary(uniqueKeysWithValues: loadedItems.map { ($0.id, $0) })
    }

    // Refreshes edge cursors so cursor pagination remains aligned to current region bounds.
    private func updateRegionCursors() {
        olderCursor = loadedItems.first.flatMap { cursor(from: $0.original) }
        newerCursor = loadedItems.last.flatMap { cursor(from: $0.original) }
    }

    // Creates an originalRef key so timeline rows can map thumbnails in O(1) by manifest path semantics.
    private func originalRef(for original: OriginalManifest) -> String {
        "\(original.metadata.deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)"
    }

    // Converts a timeline original into cursor coordinates when takenAt is present.
    private func cursor(from original: OriginalManifest) -> TimelineCursor? {
        guard let date = original.spec.takenAt else { return nil }
        return TimelineCursor(date: date, id: original.id)
    }

    // Builds month entries with cumulative offsets so sidebar navigation can convert month taps into global indices.
    private func buildMonthIndex(loader: ManifestLoaderProtocol) async throws -> [TimelineMonthEntry] {
        let monthCounts = try await loader.loadTimelineMonthCounts()
        return Self.monthEntries(from: monthCounts)
    }

    // Converts grouped month counts into cumulative offset entries so month taps can map to first-item indices.
    static func monthEntries(from monthCounts: [TimelineMonthCount]) -> [TimelineMonthEntry] {
        var offset = 0
        return monthCounts.map { monthCount in
            let entry = TimelineMonthEntry(
                yearMonth: TimelineYearMonth(year: monthCount.year, month: monthCount.month),
                count: monthCount.count,
                globalOffset: offset
            )
            offset += monthCount.count
            return entry
        }
    }

    // Seeds month-index state for unit tests that verify jump-index calculations without repository setup.
    func seedMonthIndexForTesting(_ monthCounts: [TimelineMonthCount]) {
        updateMonthIndex(Self.monthEntries(from: monthCounts))
        totalCount = monthCounts.reduce(0) { $0 + $1.count }
    }

    // Keeps raw month offsets and sidebar display sections in sync so runtime and tests observe one canonical month model.
    private func updateMonthIndex(_ entries: [TimelineMonthEntry]) {
        monthIndex = entries
        monthSelection.sections = TimelineMonthSidebarSection.sections(from: entries)
    }

    // Broadcasts load-generation increments to UIKit coordinator observers without publishing manager-wide objectWillChange.
    private func incrementLoadGeneration() {
        loadGeneration += 1
        loadGenerationPublisher.send(loadGeneration)
    }

    // MARK: - Disk cache warming

    /// Schedules debounced background warming of the top and main
    /// disk caches with the newest thumbnails. Called after initial
    /// timeline load and after each database change (sync/upload).
    private func scheduleDiskCacheWarming() {
        guard let manifestLoader, let repository, let lfsClient,
              totalCount > 0 else { return }

        warmTopTask?.cancel()
        warmTopTask = Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self.warmDiskCache(
                itemCount: CacheSettingsManager.shared.topCacheWarmItemCount,
                loader: manifestLoader,
                repository: repository,
                lfsClient: lfsClient,
                isTop: true
            )
        }

        warmMainTask?.cancel()
        warmMainTask = Task(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self.warmDiskCache(
                itemCount: CacheSettingsManager.shared.mainCacheWarmItemCount,
                loader: manifestLoader,
                repository: repository,
                lfsClient: lfsClient,
                isTop: false
            )
        }
    }

    /// Warms a disk cache tier with thumbnails of the newest
    /// timeline items. Runs sequentially at low priority so it
    /// doesn't compete with interactive browsing.
    private func warmDiskCache(
        itemCount: Int,
        loader: ManifestLoaderProtocol,
        repository: Repository,
        lfsClient: GitLFS,
        isTop: Bool
    ) async {
        do {
            let total = try await loader.countTimelineOriginals()
            guard total > 0 else { return }
            let offset = max(0, total - itemCount)
            let limit = min(itemCount, total)
            let originals = try await loader.loadTimelinePage(
                offset: offset, limit: limit
            )
            guard !Task.isCancelled else { return }

            let refs = originals.map { original in
                "\(original.metadata.deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)"
            }
            let thumbnails = try await loader.loadThumbnailsByOriginalRefs(refs)
            guard !Task.isCancelled else { return }

            for original in originals {
                guard !Task.isCancelled else { return }
                let ref = "\(original.metadata.deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)"
                guard let thumbnailSet = thumbnails[ref],
                      let entry = thumbnailSet.spec.thumbnails
                        .sorted(by: { $0.width < $1.width })
                        .first(where: { $0.width >= 225 })
                        ?? thumbnailSet.spec.thumbnails
                            .sorted(by: { $0.width < $1.width }).last
                else { continue }

                let deviceSpace = thumbnailSet.metadata.deviceSpace
                let path = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(entry.name))"

                do {
                    if isTop {
                        try await ImageDiskCacheManager.shared.warmTop(
                            priority: .topWarm,
                            itemId: original.spec.id,
                            lfsPath: path,
                            repository: repository,
                            lfsClient: lfsClient
                        )
                    } else {
                        try await ImageDiskCacheManager.shared.warmMain(
                            priority: .mainWarm,
                            itemId: original.spec.id,
                            lfsPath: path,
                            repository: repository,
                            lfsClient: lfsClient
                        )
                    }
                } catch {
                    logDebug("Disk cache warm failed for \(original.spec.id): \(error.localizedDescription)", context: "Cache")
                }
            }
            logDebug("Disk cache warm (\(isTop ? "top" : "main")) finished for \(originals.count) items", context: "Cache")
        } catch {
            logDebug("Disk cache warm error: \(error.localizedDescription)", context: "Cache")
        }
    }

}

enum TimelineError: Error {
    case repositoryNotFound
    case lfsUrlNotConfigured
    case repositoryNotInitialized
    case manifestLoadFailed(String)
    case thumbnailLoadFailed(String)
}
