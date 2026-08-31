import Foundation
import LibGit2
import GitDB

/// Coordinates two disk LRU caches — "top" (fast first-screen
/// renders) and "main" (general browsing) — and routes all image
/// byte reads through them. Runs on its own serial executor so
/// image load orchestration never contends with the main thread.
///
/// Read order: in-memory (caller) -> top disk -> main disk -> LFS.
/// Browsing reads populate only the main cache on a miss. The top
/// cache is written exclusively by the warming routine so that
/// scrolling to old items can never evict recent thumbnails.
actor ImageDiskCacheManager {
    static let shared = ImageDiskCacheManager()
    private static let lfsMaxConcurrentRequests = 6

    let mainCache: DiskImageCache
    let topCache: DiskImageCache

    private var settingsObserver: NSObjectProtocol?
    private let scheduler: LFSRequestScheduler

    enum Kind: Sendable { case thumbnail, original }

    /// Stats snapshot returned to the settings UI.
    struct CacheStats: Sendable {
        let mainSizeBytes: Int
        let mainItemCount: Int
        let topSizeBytes: Int
        let topItemCount: Int
    }

    /// Reads persisted cache budgets at startup while reusing the same
    /// clamping rules as the settings manager to avoid overflow-prone byte math.
    private init() {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("replycant-image-cache")

        let mainLimitMB = UserDefaults.standard.integer(forKey: "mainDiskCacheLimitMB")
        let topLimitMB = UserDefaults.standard.integer(forKey: "topDiskCacheLimitMB")
        let mainLimitBytes = CacheSettingsManager.clampedDiskCacheBytes(
            storedMB: mainLimitMB,
            defaultMB: 1024
        )
        let topLimitBytes = CacheSettingsManager.clampedDiskCacheBytes(
            storedMB: topLimitMB,
            defaultMB: 100
        )

        mainCache = DiskImageCache(
            directory: base.appendingPathComponent("main"),
            maxBytes: mainLimitBytes
        )
        topCache = DiskImageCache(
            directory: base.appendingPathComponent("top"),
            maxBytes: topLimitBytes
        )
        scheduler = LFSRequestScheduler(
            maxConcurrent: Self.lfsMaxConcurrentRequests
        )
        settingsObserver = nil
    }

    /// Subscribes to cache-settings changes so disk budgets stay in
    /// sync with user preferences. Call once after first access.
    func startObservingSettings() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .cacheSettingsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.applySettings() }
        }
    }

    /// Scans both cache directories so entries from previous
    /// sessions are available immediately after launch.
    func rebuild() async {
        await mainCache.rebuild()
        await topCache.rebuild()
    }

    // MARK: - Read path (browsing)

    /// Fetches decrypted image bytes through the two-tier disk
    /// cache, falling back to LFS on a full miss. Only the main
    /// cache is populated on a miss — the top cache is reserved
    /// for the warming routine.
    func loadImageData(
        kind: Kind,
        priority: ImageLoadPriority,
        itemId: String,
        lfsPath: String,
        repository: Repository,
        lfsClient: GitLFS
    ) async throws -> Data {
        let key = Self.key(kind: kind, itemId: itemId)

        if let d = await topCache.data(forKey: key) { return d }
        if let d = await mainCache.data(forKey: key) { return d }

        let d = try await scheduler.run(priority: priority, key: key) {
            try await EncryptedLFS.loadEncryptedLFSData(
                from: lfsPath,
                repository: repository,
                lfsClient: lfsClient
            )
        }
        await mainCache.store(d, forKey: key)
        return d
    }

    // MARK: - Warming

    /// Warms one thumbnail into the top cache (and main via
    /// read-through) so the first screen renders without network.
    /// Idempotent: skips if already in top.
    func warmTop(
        priority: ImageLoadPriority,
        itemId: String,
        lfsPath: String,
        repository: Repository,
        lfsClient: GitLFS
    ) async throws {
        let key = Self.key(kind: .thumbnail, itemId: itemId)

        if await topCache.data(forKey: key) != nil { return }

        let data: Data
        if let cached = await mainCache.data(forKey: key) {
            data = cached
        } else {
            data = try await scheduler.run(priority: priority, key: key) {
                try await EncryptedLFS.loadEncryptedLFSData(
                    from: lfsPath,
                    repository: repository,
                    lfsClient: lfsClient
                )
            }
        }

        await topCache.store(data, forKey: key)
        await mainCache.store(data, forKey: key)
    }

    /// Warms one thumbnail into the main cache only. Skips if
    /// already present in either cache tier.
    func warmMain(
        priority: ImageLoadPriority,
        itemId: String,
        lfsPath: String,
        repository: Repository,
        lfsClient: GitLFS
    ) async throws {
        let key = Self.key(kind: .thumbnail, itemId: itemId)

        if await topCache.data(forKey: key) != nil { return }
        if await mainCache.data(forKey: key) != nil { return }

        let data = try await scheduler.run(priority: priority, key: key) {
            try await EncryptedLFS.loadEncryptedLFSData(
                from: lfsPath,
                repository: repository,
                lfsClient: lfsClient
            )
        }
        await mainCache.store(data, forKey: key)
    }

    // MARK: - Management

    func clearMain() async {
        await mainCache.removeAll()
    }

    func clearTop() async {
        await topCache.removeAll()
    }

    func stats() async -> CacheStats {
        CacheStats(
            mainSizeBytes: await mainCache.currentSizeBytes,
            mainItemCount: await mainCache.itemCount,
            topSizeBytes: await topCache.currentSizeBytes,
            topItemCount: await topCache.itemCount
        )
    }

    // MARK: - Internals

    nonisolated static func key(kind: Kind, itemId: String) -> String {
        switch kind {
        case .thumbnail: return "t/" + itemId
        case .original:  return "o/" + itemId
        }
    }

    /// Applies live settings updates using clamped values so malformed
    /// persisted numbers cannot overflow the MB-to-bytes conversion path.
    private func applySettings() async {
        let mainLimitMB = await MainActor.run { CacheSettingsManager.shared.mainDiskCacheLimitMB }
        let topLimitMB = await MainActor.run { CacheSettingsManager.shared.topDiskCacheLimitMB }
        let mainLimitBytes = CacheSettingsManager.clampedDiskCacheBytes(
            storedMB: mainLimitMB,
            defaultMB: 1024
        )
        let topLimitBytes = CacheSettingsManager.clampedDiskCacheBytes(
            storedMB: topLimitMB,
            defaultMB: 100
        )
        await mainCache.setMaxBytes(mainLimitBytes)
        await topCache.setMaxBytes(topLimitBytes)
    }
}
