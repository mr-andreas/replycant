import Foundation

// Manages cache settings for timeline image preloading.
// Stores user preferences for how many images to preload before and after the viewport
// to improve perceived scrolling performance.
@MainActor
final class CacheSettingsManager {
    static let shared = CacheSettingsManager()

    private let beforeViewportKey = "cacheImagesBeforeViewport"
    private let afterViewportKey = "cacheImagesAfterViewport"
    private let maxCacheSizeKey = "maxTimelineThumbnailRAMCacheSizeMB"
    private let localThumbnailsEnabledKey = "localThumbnailsEnabled"
    private let fullScreenPreloadRadiusKey = "fullScreenPreloadRadius"
    private let mainDiskCacheLimitKey = "mainDiskCacheLimitMB"
    private let topDiskCacheLimitKey = "topDiskCacheLimitMB"
    private let mainCacheWarmItemCountKey = "mainCacheWarmItemCount"
    private let topCacheWarmItemCountKey = "topCacheWarmItemCount"
    private let defaults: UserDefaults

    // Clamps persisted values to operationally safe ceilings so test or
    // legacy outliers cannot trigger integer overflow in preload/cache math.
    private enum Limits {
        static let viewportPreloadMax = 1_000
        static let fullScreenPreloadRadiusMax = 100
        static let timelineRamCacheMBMax = 4_096
        static let diskCacheMBMax = 65_536
        static let warmItemCountMax = 100_000
    }

    // Allows tests to use an isolated defaults suite so they cannot poison
    // app-wide settings persisted in the simulator container.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Normalizes positive integer settings to a safe range and keeps
    // defaults behavior when stored values are zero or negative.
    private func clampedPositive(
        forKey key: String,
        defaultValue: Int,
        maxValue: Int
    ) -> Int {
        let value = defaults.integer(forKey: key)
        guard value > 0 else { return defaultValue }
        return min(value, maxValue)
    }

    // Preserves explicit zero for settings where disabling a feature is valid
    // while still preventing unbounded values from propagating into index math.
    private func clampedNonNegative(
        forKey key: String,
        defaultValue: Int,
        maxValue: Int
    ) -> Int {
        guard let value = defaults.object(forKey: key) as? Int else {
            return defaultValue
        }
        guard value >= 0 else { return defaultValue }
        return min(value, maxValue)
    }

    // Converts MB budget to bytes with a final hard cap so callers outside
    // the main actor can share the same sanitization without reading defaults directly.
    nonisolated static func clampedDiskCacheBytes(
        storedMB: Int,
        defaultMB: Int
    ) -> Int {
        let boundedMB = min(max(storedMB, 1), Limits.diskCacheMBMax)
        let fallbackMB = min(max(defaultMB, 1), Limits.diskCacheMBMax)
        let safeMB = storedMB > 0 ? boundedMB : fallbackMB
        return safeMB * 1_024 * 1_024
    }

    // Number of images to preload before the current viewport.
    // Defaults to 100 if not previously configured.
    var imagesBeforeViewport: Int {
        get {
            clampedPositive(
                forKey: beforeViewportKey,
                defaultValue: 100,
                maxValue: Limits.viewportPreloadMax
            )
        }
        set {
            defaults.set(newValue, forKey: beforeViewportKey)
        }
    }

    // Number of images to preload after the current viewport.
    // Defaults to 100 if not previously configured.
    var imagesAfterViewport: Int {
        get {
            clampedPositive(
                forKey: afterViewportKey,
                defaultValue: 100,
                maxValue: Limits.viewportPreloadMax
            )
        }
        set {
            defaults.set(newValue, forKey: afterViewportKey)
        }
    }

    // Maximum RAM cache size for timeline thumbnails in megabytes.
    // Defaults to 100 MB if not previously configured.
    var maxTimelineThumbnailRAMCacheSizeMB: Int {
        get {
            clampedPositive(
                forKey: maxCacheSizeKey,
                defaultValue: 100,
                maxValue: Limits.timelineRamCacheMBMax
            )
        }
        set {
            defaults.set(newValue, forKey: maxCacheSizeKey)
            NotificationCenter.default.post(name: .cacheSettingsDidChange, object: nil)
        }
    }

    // Enables loading timeline thumbnails from local Photo Library assets before LFS fetches.
    // Defaults to true so local-first behavior is active unless users explicitly opt out.
    var localThumbnailsEnabled: Bool {
        get { defaults.object(forKey: localThumbnailsEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: localThumbnailsEnabledKey) }
    }

    // How many images to preload in each direction when viewing fullscreen.
    // 0 disables preloading entirely. Uses object(forKey:) so 0 is preserved
    // rather than collapsing to the default like the viewport counts do.
    var fullScreenPreloadRadius: Int {
        get {
            clampedNonNegative(
                forKey: fullScreenPreloadRadiusKey,
                defaultValue: 2,
                maxValue: Limits.fullScreenPreloadRadiusMax
            )
        }
        set {
            defaults.set(newValue, forKey: fullScreenPreloadRadiusKey)
        }
    }

    // Maximum on-disk size for the main LRU image cache in megabytes.
    // Holds thumbnails and full-size originals loaded during browsing.
    var mainDiskCacheLimitMB: Int {
        get {
            clampedPositive(
                forKey: mainDiskCacheLimitKey,
                defaultValue: 1024,
                maxValue: Limits.diskCacheMBMax
            )
        }
        set {
            defaults.set(newValue, forKey: mainDiskCacheLimitKey)
            NotificationCenter.default.post(name: .cacheSettingsDidChange, object: nil)
        }
    }

    // Maximum on-disk size for the top LRU cache in megabytes.
    // Keeps the most recent thumbnails so the first screen renders
    // without network access.
    var topDiskCacheLimitMB: Int {
        get {
            clampedPositive(
                forKey: topDiskCacheLimitKey,
                defaultValue: 100,
                maxValue: Limits.diskCacheMBMax
            )
        }
        set {
            defaults.set(newValue, forKey: topDiskCacheLimitKey)
            NotificationCenter.default.post(name: .cacheSettingsDidChange, object: nil)
        }
    }

    // How many of the newest timeline items to warm into the main
    // cache after a sync completes. Larger values improve cold-start
    // browsing at the cost of background bandwidth.
    var mainCacheWarmItemCount: Int {
        get {
            clampedPositive(
                forKey: mainCacheWarmItemCountKey,
                defaultValue: 1000,
                maxValue: Limits.warmItemCountMax
            )
        }
        set {
            defaults.set(newValue, forKey: mainCacheWarmItemCountKey)
        }
    }

    // How many of the newest timeline items to warm into the top
    // cache so the first screen is always fast.
    var topCacheWarmItemCount: Int {
        get {
            clampedPositive(
                forKey: topCacheWarmItemCountKey,
                defaultValue: 300,
                maxValue: Limits.warmItemCountMax
            )
        }
        set {
            defaults.set(newValue, forKey: topCacheWarmItemCountKey)
        }
    }
}

extension Notification.Name {
    static let cacheSettingsDidChange = Notification.Name("cacheSettingsDidChange")
}


