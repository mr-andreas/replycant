import Foundation
import LibGit2
import SwiftUI
import Combine
import GitDB
import SparseGrid
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
    @Published var totalCount = 0 {
        didSet {
            window.totalCount = totalCount
            prefetch.noteTotalCount(totalCount)
        }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    var loadGeneration: Int { window.revision }
    var loadGenerationPublisher: AnyPublisher<Int, Never> { window.revisionPublisher }
    @Published private(set) var monthIndex: [TimelineMonthEntry] = []
    let monthSelection = TimelineMonthSelectionModel()
    @Published var scrollTargetIndex: Int?

    // Tells the map to recluster after a sync changes which photos exist.
    let contentDidChange = PassthroughSubject<Void, Never>()
    fileprivate let scope: TimelineScope

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
    fileprivate var manifestLoader: ManifestLoaderProtocol?
    private var databaseChangeCancellable: AnyCancellable?
    // Buffers per-commit notifications so a sync run refreshes the count
    // once per burst instead of once per photo.
    private var changeCoalescer = ManifestChangeCoalescer()
    private var databaseChangeDrainTask: Task<Void, Never>?
    private let databaseChangeDrainDelay: UInt64 = 300_000_000
    // The grid is still coasting, so the buffered burst stays unapplied.
    // Publishing it now reloads the collection view and stops the flick.
    private var databaseChangeHeldForScroll = false

    // The package owns the loaded run and which indices to warm. This
    // manager only turns manifest pages into items and fetches thumbnail bytes.
    private let pageSource: TimelinePageSource
    private let window: SparseIndexWindow<TimelineItem>
    private let prefetch: SparsePrefetchQueue<TimelineItem>
    var loadedItems: [TimelineItem] { window.items }

    // Image loaders for rows the grid asked to warm ahead of the viewport.
    // Keyed by item id so a row that scrolls into view can reuse the fetch.
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
    // Spans the moment a reset's rebuild holds the database, without retrying
    // long enough to hide a real failure. The window only has to outlast the
    // rebuild's grip on the file, not the rebuild itself: once the reload binds
    // successfully, remaining rows arrive through the change subscription.
    private static let databaseReloadAttempts = 6
    private static let databaseReloadRetryDelayNanoseconds: UInt64 = 500_000_000
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
        scope: TimelineScope = .all,
        photoLibrary: PhotoLibraryProviding = PhotoLibraryManager(),
        notificationCenter: NotificationCenter = .default
    ) {
        let pageSource = TimelinePageSource()
        let window = SparseIndexWindow<TimelineItem>(source: pageSource)
        let prefetch = SparsePrefetchQueue(window: window)
        self.pageSource = pageSource
        self.window = window
        self.prefetch = prefetch
        self.scope = scope
        self.photoLibrary = photoLibrary
        self.notificationCenter = notificationCenter
        pageSource.owner = self
        prefetch.loader = self
        window.onLoadError = { [weak self] error in
            guard let self, !(error is TimelinePageUnavailable) else { return }
            self.errorMessage = error.localizedDescription
            logError(
                "Failed to load sparse timeline page: \(error.localizedDescription)",
                context: "Timeline"
            )
        }
        window.onRegionReset = { [weak self] in
            guard let self else { return }
            self.thumbnailMap.removeAll()
            self.prefetch.resetPrefetch(clearVisibleIndices: false)
        }
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
                logError("Turn on upload from the timeline or Settings, then try again", context: "Timeline")
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
                        self?.receiveDatabaseChange(change)
                    }
                }

            resetLoadedRegion(clearVisibleIndices: true)
            let countSignpost = AppSignposts.begin("TimelineCountItems")
            do {
                defer {
                    AppSignposts.end("TimelineCountItems", countSignpost)
                }
                totalCount = try await manifestManager.countTimelineOriginals(scope: scope)
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

    // Returns every placed photo so the map can cluster without decoding manifests.
    func loadGeotaggedPoints() async throws -> [MapMediaPoint] {
        guard let manifestLoader else { return [] }
        return try await manifestLoader.loadGeotaggedPoints()
    }

    // Loads the tile photos for the clusters currently on screen, including
    // their thumbnails, and keeps them in the shared thumbnail map.
    func loadItems(ids: [String]) async throws -> [TimelineItem] {
        guard let manifestLoader, !ids.isEmpty else { return [] }
        let originals = try await manifestLoader.loadOriginals(ids: ids)
        let refs = originals.map { originalRef(for: $0) }
        let thumbnails = try await manifestLoader.loadThumbnailsByOriginalRefs(refs)
        thumbnailMap.merge(thumbnails) { _, new in new }
        return originals.map { original in
            TimelineItem(original: original, thumbnail: thumbnailMap[originalRef(for: original)])
        }
    }

    // Returns one loaded timeline item when the requested global index is currently present in memory.
    func item(at index: Int) -> TimelineItem? {
        window.item(at: index)
    }

    // Maps a photo the grid is already showing back to its global index.
    // Older history synced in above the window moves that index, and the
    // grid needs the new one to keep the same photo on screen.
    func index(ofItemId id: String) -> Int? {
        window.index(of: id)
    }

    var canLoadOlder: Bool { window.canLoadOlder }

    var canLoadNewer: Bool { window.canLoadNewer }

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
    /// off-screen images begin loading without the 150ms debounce delay,
    /// and applies any database burst that was held for the flick.
    func setGridScrolling(_ isScrolling: Bool) {
        guard isGridScrolling != isScrolling else { return }
        monthSelection.isGridScrolling = isScrolling
        prefetch.setScrolling(isScrolling)
        if !isScrolling {
            updateCurrentMonth(for: pendingMonthIndex, force: true)
            flushDatabaseChangeHeldForScroll()
        }
    }

    // Asks the window for the page that covers this index. The window
    // extends the current run or replaces it; this manager only supplies pages.
    func ensureLoaded(around index: Int) async {
        await window.ensureLoaded(around: index)
    }

    // Loads a radius around a fullscreen index so a swipe still has rows
    // when it reaches the edge of the run that was on screen.
    func ensureWindowLoaded(around index: Int, radius: Int = 30) async {
        await window.ensureWindowLoaded(around: index, radius: radius)
    }

    // The fullscreen viewer is about to swipe past the loaded rows, so
    // the window extends by one page in that direction.
    func loadOlderPage() async {
        await window.loadOlderPage()
    }

    func loadNewerPage() async {
        await window.loadNewerPage()
    }

    // Folds one frame of visible indices into a single neighbor-page fetch.
    func schedulePaging(around index: Int) {
        window.schedulePaging(around: index)
    }

    // Records a row entering the viewport so the warm span can follow it.
    func itemDidAppear(at index: Int) {
        prefetch.itemDidAppear(at: index)
    }

    // Records a row leaving the viewport so the warm span can follow it.
    func itemDidDisappear(at index: Int) {
        prefetch.itemDidDisappear(at: index)
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
            await RetryBudget.run(
                attempts: Self.databaseReloadAttempts,
                delayNanoseconds: Self.databaseReloadRetryDelayNanoseconds
            ) { [weak self] in
                guard let self else { return true }
                await self.loadTimeline(force: true)
                return self.errorMessage == nil
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
        databaseChangeDrainTask?.cancel()
        databaseChangeDrainTask = nil
        databaseChangeHeldForScroll = false
        changeCoalescer = ManifestChangeCoalescer()
        resetLoadedRegion(clearVisibleIndices: false)
    }

    // Buffers one database event and refreshes the timeline once the burst
    // settles. Each event otherwise re-counts the library on the main actor.
    func receiveDatabaseChange(_ change: ManifestDatabaseChange) {
        changeCoalescer.ingest(change)
        scheduleDatabaseChangeDrain()
    }

    // Trailing window, same shape as the preload debounce, so a run of
    // commits becomes one count and one month refresh. A main-actor task
    // is used so the wait participates in the same executor as the refresh.
    private func scheduleDatabaseChangeDrain() {
        databaseChangeDrainTask?.cancel()
        databaseChangeDrainTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.databaseChangeDrainDelay ?? 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.drainCoalescedDatabaseChange()
        }
    }

    // Applies the merged burst. A drain with nothing pending is a no-op so a
    // cancelled window cannot refresh twice. A flick keeps the burst: the
    // grid reload that follows a count change cancels deceleration.
    private func drainCoalescedDatabaseChange() async {
        if isGridScrolling {
            databaseChangeHeldForScroll = true
            return
        }
        guard let change = changeCoalescer.drain() else { return }
        await handleDatabaseChange(change)
    }

    // The count can finish after a flick has started. Put this burst back
    // ahead of any commits that landed while the count ran, and wait until
    // the coast ends so the grid is not reloaded mid-flick.
    private func holdDatabaseChangeForScroll(_ change: ManifestDatabaseChange) {
        let newer = changeCoalescer.drain()
        changeCoalescer.ingest(change)
        if let newer {
            changeCoalescer.ingest(newer)
        }
        databaseChangeHeldForScroll = true
    }

    // Applies a burst that was kept back for a flick, without waiting out
    // another debounce. The coast is already over, so the photo should
    // show up on the next turn.
    private func flushDatabaseChangeHeldForScroll() {
        guard databaseChangeHeldForScroll else { return }
        databaseChangeHeldForScroll = false
        databaseChangeDrainTask?.cancel()
        databaseChangeDrainTask = Task { [weak self] in
            await self?.drainCoalescedDatabaseChange()
        }
    }

    // Applies database change events to sparse timeline state so UI updates without full reloads.
    private func handleDatabaseChange(_ change: ManifestDatabaseChange) async {
        guard let manifestLoader else {
            applyDatabaseChange(change, refreshedTotalCount: 0)
            return
        }
        do {
            let refreshedTotalCount = try await manifestLoader.countTimelineOriginals(scope: scope)
            if isGridScrolling {
                holdDatabaseChangeForScroll(change)
                return
            }
            applyDatabaseChange(change, refreshedTotalCount: refreshedTotalCount)
            // A full replace drops the loaded window. The grid does not
            // reload when the count stays the same, so those cells still
            // show photos that can no longer be opened. Load that page back.
            if case .fullReplace = change, refreshedTotalCount > 0 {
                let saved = savedViewportAnchorIndex ?? (refreshedTotalCount - 1)
                let anchor = min(max(0, saved), refreshedTotalCount - 1)
                await ensureLoaded(around: anchor)
            }
            updateMonthIndex(try await buildMonthIndex(loader: manifestLoader))
            if refreshedTotalCount == 0 {
                monthSelection.currentYearMonth = nil
            }
            scheduleDiskCacheWarming()
            contentDidChange.send(())
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
        prefetch.noteTotalCount(refreshedTotalCount)
        let loadedOriginalRefs = Set(loadedItems.map { originalRef(for: $0.original) })
        var shouldReconfigureVisibleCells = false

        let addedOriginals = mutation.added.compactMap { $0 as? OriginalManifest }
            .filter { scope.contains($0) }
        let removedOriginals = mutation.removed.compactMap { $0 as? OriginalManifest }
            .filter { scope.contains($0) }
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

        if !removedOriginalIds.isEmpty {
            prefetch.forget(removedOriginalIds)
        }

        window.updateRegion { region in
            let loadedItemIds = Set(region.items.map(\.id))
            var knownIds = loadedItemIds
            let previousOffset = region.loadedOffset
            var addedOriginalsWithinWindow: [OriginalManifest] = []
            if let firstLoaded = region.items.first?.original,
               let firstLoadedDate = firstLoaded.spec.takenAt {
                let firstLoadedKey = (firstLoadedDate, firstLoaded.id)
                let addedBeforeWindow = addedOriginals.filter {
                    guard let date = $0.spec.takenAt else { return false }
                    return (date, $0.id) < firstLoadedKey
                }.count
                region.loadedOffset += addedBeforeWindow

                if let lastLoaded = region.items.last?.original,
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
                region.loadedOffset = max(0, region.loadedOffset - removedBeforeWindow)
            }
            if region.loadedOffset != previousOffset {
                shouldReconfigureVisibleCells = true
            }

            if !removedOriginalIds.isEmpty {
                region.items.removeAll { removedOriginalIds.contains($0.id) }
                if !removedOriginalIds.isDisjoint(with: loadedItemIds) {
                    shouldReconfigureVisibleCells = true
                }
                knownIds.subtract(removedOriginalIds)
            }

            if !addedOriginalsWithinWindow.isEmpty {
                let insertedItems = addedOriginalsWithinWindow
                    .filter { !knownIds.contains($0.id) && !removedOriginalIds.contains($0.id) }
                    .map { original in
                        TimelineItem(
                            original: original,
                            thumbnail: self.thumbnailMap[self.originalRef(for: original)]
                        )
                    }
                if !insertedItems.isEmpty {
                    region.items.append(contentsOf: insertedItems)
                    region.items.sort { lhs, rhs in
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
                for index in region.items.indices {
                    let existingItem = region.items[index]
                    guard let updatedOriginal = updatedOriginalsById[existingItem.id] else { continue }
                    shouldReconfigureVisibleCells = true
                    region.items[index] = TimelineItem(
                        original: updatedOriginal,
                        thumbnail: self.thumbnailMap[self.originalRef(for: updatedOriginal)]
                    )
                }
            }

            for index in region.items.indices {
                let item = region.items[index]
                let ref = self.originalRef(for: item.original)
                guard let updatedThumbnail = self.thumbnailMap[ref] else { continue }
                guard item.thumbnail?.id != updatedThumbnail.id
                    || item.thumbnail?.spec.thumbnails != updatedThumbnail.spec.thumbnails else { continue }
                shouldReconfigureVisibleCells = true
                region.items[index] = TimelineItem(original: item.original, thumbnail: updatedThumbnail)
            }
            return shouldReconfigureVisibleCells
        }
    }

    // Seeds sparse region state for focused unit tests without requiring repository or database wiring.
    func seedLoadedRegionForTesting(offset: Int, items: [TimelineItem], totalCount: Int) {
        self.totalCount = totalCount
        window.updateRegion { region in
            region.loadedOffset = offset
            region.items = items
            return false
        }
        thumbnailMap = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let thumbnail = item.thumbnail else { return nil }
            return (thumbnail.spec.originalRef, thumbnail)
        })
        prefetch.resetPrefetch(clearVisibleIndices: false)
    }

    // Lets a test count refreshes without opening the shared manifest database.
    func setManifestLoaderForTesting(_ loader: ManifestLoaderProtocol?) {
        manifestLoader = loader
    }

    // Lets a burst test wait until the trailing window drains. A fixed
    // sleep races the main actor: under CI the assertion resumed before
    // this task started its debounce, so the count looked missing.
    func waitForDatabaseChangeDrainForTesting() async {
        await databaseChangeDrainTask?.value
    }

    // Resets loaded items so sparse state can be rebuilt from a new jump position.
    // The window's reset drops the thumbnail map and the warm set. Visible
    // indices stay unless this reload is discarding the grid's viewport too.
    private func resetLoadedRegion(clearVisibleIndices: Bool, clearCurrentMonth: Bool = true) {
        window.reset()
        if clearCurrentMonth {
            monthSelection.currentYearMonth = nil
        }
        if clearVisibleIndices {
            prefetch.resetPrefetch(clearVisibleIndices: true)
        }
    }

    // Pairs originals with the thumbnail sets fetched for that page.
    // The window stores the pair so a cell does not query the manifest again.
    fileprivate func itemsWithThumbnails(
        from originals: [OriginalManifest],
        loader: ManifestLoaderProtocol
    ) async throws -> [TimelineItem] {
        let refs = originals.map { originalRef(for: $0) }
        let thumbnails = try await loader.loadThumbnailsByOriginalRefs(refs)
        thumbnailMap.merge(thumbnails) { _, new in new }
        return originals.map { original in
            TimelineItem(
                original: original,
                thumbnail: thumbnailMap[originalRef(for: original)]
            )
        }
    }

    // Creates an originalRef key so timeline rows can map thumbnails in O(1) by manifest path semantics.
    private func originalRef(for original: OriginalManifest) -> String {
        "\(original.metadata.deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)"
    }

    // Converts a timeline original into cursor coordinates when takenAt is present.
    fileprivate func cursor(from original: OriginalManifest) -> TimelineCursor? {
        guard let date = original.spec.takenAt else { return nil }
        return TimelineCursor(date: date, id: original.id)
    }

    // Builds month entries with cumulative offsets so sidebar navigation can convert month taps into global indices.
    private func buildMonthIndex(loader: ManifestLoaderProtocol) async throws -> [TimelineMonthEntry] {
        let monthCounts = try await loader.loadTimelineMonthCounts(scope: scope)
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

    // MARK: - Disk cache warming

    /// Schedules debounced background warming of the top and main
    /// disk caches with the newest thumbnails. Called after initial
    /// timeline load and after each database change (sync/upload).
    private func scheduleDiskCacheWarming() {
        // The map and place screens share this manager. Warming their
        // subsets would repeat the full timeline's cache work.
        guard scope == .all else { return }
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

    // Uses the shared newest-thumbnail choice so a charging wake and
    // the open timeline fill the same cache. The tier decides whether
    // a hit is reserved for the first screen or for later browsing.
    // Only the top tier is listed on the Cache page, and only once this
    // warm has started, so a debounce that never runs is not a row.
    private func warmDiskCache(
        itemCount: Int,
        loader: ManifestLoaderProtocol,
        repository: Repository,
        lfsClient: GitLFS,
        isTop: Bool
    ) async {
        let warmThumbnails = { () async -> Void in
            await DiskCacheWarming.warmNewest(
                itemCount: itemCount,
                scope: self.scope,
                loader: loader
            ) { request in
                if isTop {
                    try await ImageDiskCacheManager.shared.warmTop(
                        priority: .topWarm,
                        itemId: request.itemId,
                        lfsPath: request.lfsPath,
                        repository: repository,
                        lfsClient: lfsClient
                    )
                } else {
                    try await ImageDiskCacheManager.shared.warmMain(
                        priority: .mainWarm,
                        itemId: request.itemId,
                        lfsPath: request.lfsPath,
                        repository: repository,
                        lfsClient: lfsClient
                    )
                }
            }
        }
        if isTop {
            await TopCacheRefreshLog.shared.record(source: .open, warm: warmThumbnails)
        } else {
            await warmThumbnails()
        }
    }

}

// A page fetch ran before the manifest database was bound. The window
// reports it, and the manager ignores it so a not-yet-loaded timeline
// does not replace its range with an empty page.
private struct TimelinePageUnavailable: Error {}

// Turns manifest pages into timeline items. The window asks for a page
// by offset or by the item on either edge; the cursor stays here because
// it is the original's capture time and id.
@MainActor
private final class TimelinePageSource: SparsePageSource {
    typealias Item = TimelineItem
    weak var owner: TimelineManager?

    func loadPage(offset: Int, limit: Int) async throws -> [TimelineItem] {
        let (owner, loader) = try requireLoader()
        let signpostLog = OSLog(subsystem: appLogSubsystem, category: "PointsOfInterest")
        let signpostID = OSSignpostID(log: signpostLog)
        var loadTimelinePageMs = 0.0
        os_signpost(
            .begin,
            log: signpostLog,
            name: "TimelineLoadFreshRegion",
            signpostID: signpostID,
            "offset=%{public}d",
            offset
        )
        defer {
            os_signpost(
                .end,
                log: signpostLog,
                name: "TimelineLoadFreshRegion",
                signpostID: signpostID,
                "loadTimelinePageMs=%{public}.2f",
                loadTimelinePageMs
            )
        }
        let pageLoadStart = DispatchTime.now().uptimeNanoseconds
        let originals: [OriginalManifest]
        do {
            originals = try await loader.loadTimelinePage(
                offset: offset,
                limit: limit,
                scope: owner.scope
            )
        } catch {
            let pageLoadEnd = DispatchTime.now().uptimeNanoseconds
            loadTimelinePageMs = Double(pageLoadEnd - pageLoadStart) / 1_000_000
            throw error
        }
        let pageLoadEnd = DispatchTime.now().uptimeNanoseconds
        loadTimelinePageMs = Double(pageLoadEnd - pageLoadStart) / 1_000_000
        return try await owner.itemsWithThumbnails(from: originals, loader: loader)
    }

    func loadPage(before item: TimelineItem, limit: Int) async throws -> [TimelineItem] {
        let (owner, loader) = try requireLoader()
        guard let cursor = owner.cursor(from: item.original) else { return [] }
        let signpost = AppSignposts.begin("TimelinePrependRegion")
        defer { AppSignposts.end("TimelinePrependRegion", signpost) }
        let originals = try await loader.loadTimelinePage(
            before: cursor,
            limit: limit,
            scope: owner.scope
        )
        return try await owner.itemsWithThumbnails(from: originals, loader: loader)
    }

    func loadPage(after item: TimelineItem, limit: Int) async throws -> [TimelineItem] {
        let (owner, loader) = try requireLoader()
        guard let cursor = owner.cursor(from: item.original) else { return [] }
        let signpost = AppSignposts.begin("TimelineAppendRegion")
        defer { AppSignposts.end("TimelineAppendRegion", signpost) }
        let originals = try await loader.loadTimelinePage(
            after: cursor,
            limit: limit,
            scope: owner.scope
        )
        return try await owner.itemsWithThumbnails(from: originals, loader: loader)
    }

    private func requireLoader() throws -> (TimelineManager, ManifestLoaderProtocol) {
        guard let owner, let loader = owner.manifestLoader else {
            throw TimelinePageUnavailable()
        }
        return (owner, loader)
    }
}

extension TimelineManager: SparseItemLoader {
    // The warm span reads the cache settings on each pass, so a change
    // in Settings applies the next time the viewport settles.
    func prefetchMargins() -> (before: Int, after: Int) {
        let settings = CacheSettingsManager.shared
        return (settings.imagesBeforeViewport, settings.imagesAfterViewport)
    }

    // Starts a thumbnail fetch for one row the grid is about to show.
    // A cached image or a fetch already in flight is left alone.
    func loadItem(id: String) {
        if imageCache.get(for: id) != nil { return }
        if preloadImageLoaders[id] != nil { return }
        guard let index = window.index(of: id), let item = window.item(at: index) else { return }
        let loader = ImageLoader(
            item: item,
            priority: .timelinePage,
            timelineManager: self
        )
        preloadImageLoaders[id] = loader
        preloadCancellables[id] = loader.$image
            .compactMap { $0 }
            .sink { [weak self] loadedImage in
                self?.cacheImage(loadedImage, for: id)
            }
        loader.loadImage()
    }

    // Stops a warm fetch whose row has left the span, so it releases
    // its LFS concurrency slot.
    func cancelItem(id: String) {
        preloadImageLoaders.removeValue(forKey: id)?.cancelLoading()
        preloadCancellables.removeValue(forKey: id)?.cancel()
    }
}

extension TimelineManager: SparseGridModel {
    var revisionPublisher: AnyPublisher<Int, Never> { loadGenerationPublisher }

    var totalCountPublisher: AnyPublisher<Int, Never> {
        $totalCount.eraseToAnyPublisher()
    }

    var scrollTargetIndexPublisher: AnyPublisher<Int?, Never> {
        $scrollTargetIndex.eraseToAnyPublisher()
    }

    // The id the grid binds to a cell. Nil means that index is not in
    // the loaded window, so the cell stays a placeholder.
    func itemId(at index: Int) -> String? {
        item(at: index)?.id
    }
}

enum TimelineError: Error {
    case repositoryNotFound
    case lfsUrlNotConfigured
    case repositoryNotInitialized
    case manifestLoadFailed(String)
    case thumbnailLoadFailed(String)
}
