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
    
    private init() {}
    
    // Number of images to preload before the current viewport.
    // Defaults to 100 if not previously configured.
    var imagesBeforeViewport: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: beforeViewportKey)
            return value > 0 ? value : 100
        }
        set {
            UserDefaults.standard.set(newValue, forKey: beforeViewportKey)
        }
    }
    
    // Number of images to preload after the current viewport.
    // Defaults to 100 if not previously configured.
    var imagesAfterViewport: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: afterViewportKey)
            return value > 0 ? value : 100
        }
        set {
            UserDefaults.standard.set(newValue, forKey: afterViewportKey)
        }
    }
    
    // Maximum RAM cache size for timeline thumbnails in megabytes.
    // Defaults to 100 MB if not previously configured.
    var maxTimelineThumbnailRAMCacheSizeMB: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: maxCacheSizeKey)
            return value > 0 ? value : 100
        }
        set {
            UserDefaults.standard.set(newValue, forKey: maxCacheSizeKey)
            NotificationCenter.default.post(name: .cacheSettingsDidChange, object: nil)
        }
    }

    // Enables loading timeline thumbnails from local Photo Library assets before LFS fetches.
    // Defaults to true so local-first behavior is active unless users explicitly opt out.
    var localThumbnailsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: localThumbnailsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: localThumbnailsEnabledKey) }
    }

    // How many images to preload in each direction when viewing fullscreen.
    // 0 disables preloading entirely. Uses object(forKey:) so 0 is preserved
    // rather than collapsing to the default like the viewport counts do.
    var fullScreenPreloadRadius: Int {
        get {
            UserDefaults.standard.object(forKey: fullScreenPreloadRadiusKey) as? Int ?? 2
        }
        set {
            UserDefaults.standard.set(newValue, forKey: fullScreenPreloadRadiusKey)
        }
    }

    // Maximum on-disk size for the main LRU image cache in megabytes.
    // Holds thumbnails and full-size originals loaded during browsing.
    var mainDiskCacheLimitMB: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: mainDiskCacheLimitKey)
            return value > 0 ? value : 1024
        }
        set {
            UserDefaults.standard.set(newValue, forKey: mainDiskCacheLimitKey)
            NotificationCenter.default.post(name: .cacheSettingsDidChange, object: nil)
        }
    }

    // Maximum on-disk size for the top LRU cache in megabytes.
    // Keeps the most recent thumbnails so the first screen renders
    // without network access.
    var topDiskCacheLimitMB: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: topDiskCacheLimitKey)
            return value > 0 ? value : 100
        }
        set {
            UserDefaults.standard.set(newValue, forKey: topDiskCacheLimitKey)
            NotificationCenter.default.post(name: .cacheSettingsDidChange, object: nil)
        }
    }

    // How many of the newest timeline items to warm into the main
    // cache after a sync completes. Larger values improve cold-start
    // browsing at the cost of background bandwidth.
    var mainCacheWarmItemCount: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: mainCacheWarmItemCountKey)
            return value > 0 ? value : 1000
        }
        set {
            UserDefaults.standard.set(newValue, forKey: mainCacheWarmItemCountKey)
        }
    }

    // How many of the newest timeline items to warm into the top
    // cache so the first screen is always fast.
    var topCacheWarmItemCount: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: topCacheWarmItemCountKey)
            return value > 0 ? value : 300
        }
        set {
            UserDefaults.standard.set(newValue, forKey: topCacheWarmItemCountKey)
        }
    }
}

extension Notification.Name {
    static let cacheSettingsDidChange = Notification.Name("cacheSettingsDidChange")
}


