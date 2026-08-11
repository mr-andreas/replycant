import Foundation
import Testing
@testable import iosapp

// Tests cache setting defaults, persistence, and clamp behavior using
// isolated UserDefaults domains so test runs never mutate app state.
@MainActor
struct CacheSettingsManagerTests {

    // Creates an isolated defaults domain so each test runs without
    // leaking values into the simulator's app container.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "CacheSettingsManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // Creates a manager bound to test-scoped defaults for deterministic reads.
    private func makeManager() -> (CacheSettingsManager, UserDefaults) {
        let defaults = makeIsolatedDefaults()
        return (CacheSettingsManager(defaults: defaults), defaults)
    }

    // Verifies default values remain stable when no settings are configured.
    @Test func testDefaultValues() {
        let (manager, _) = makeManager()
        #expect(manager.imagesBeforeViewport == 100)
        #expect(manager.imagesAfterViewport == 100)
        #expect(manager.maxTimelineThumbnailRAMCacheSizeMB == 100)
        #expect(manager.fullScreenPreloadRadius == 2)
        #expect(manager.mainDiskCacheLimitMB == 1024)
        #expect(manager.topDiskCacheLimitMB == 100)
        #expect(manager.mainCacheWarmItemCount == 1000)
        #expect(manager.topCacheWarmItemCount == 300)
        #expect(manager.localThumbnailsEnabled)
    }

    // Verifies viewport preload values persist and round trip when in range.
    @Test func testViewportPreloadValuesPersist() {
        let (manager, defaults) = makeManager()
        manager.imagesBeforeViewport = 15
        manager.imagesAfterViewport = 25

        #expect(manager.imagesBeforeViewport == 15)
        #expect(manager.imagesAfterViewport == 25)
        #expect(defaults.integer(forKey: "cacheImagesBeforeViewport") == 15)
        #expect(defaults.integer(forKey: "cacheImagesAfterViewport") == 25)
    }

    // Verifies poisoned Int.max preload settings are clamped to prevent
    // downstream preload index arithmetic overflow.
    @Test func testViewportPreloadValuesClampFromIntMax() {
        let (manager, defaults) = makeManager()
        defaults.set(Int.max, forKey: "cacheImagesBeforeViewport")
        defaults.set(Int.max, forKey: "cacheImagesAfterViewport")

        #expect(manager.imagesBeforeViewport == 1000)
        #expect(manager.imagesAfterViewport == 1000)
    }

    // Verifies non-positive stored preload values still map to defaults.
    @Test func testViewportPreloadValuesFallbackWhenNonPositive() {
        let (manager, defaults) = makeManager()
        defaults.set(0, forKey: "cacheImagesBeforeViewport")
        defaults.set(-5, forKey: "cacheImagesAfterViewport")

        #expect(manager.imagesBeforeViewport == 100)
        #expect(manager.imagesAfterViewport == 100)
    }

    // Verifies local-thumbnail toggle persists because multiple loaders
    // branch on this flag before touching Photos APIs.
    @Test func testLocalThumbnailsEnabledPersists() {
        let (manager, defaults) = makeManager()
        manager.localThumbnailsEnabled = false
        #expect(manager.localThumbnailsEnabled == false)
        #expect(defaults.object(forKey: "localThumbnailsEnabled") as? Bool == false)
    }

    // Verifies fullscreen preload preserves explicit zero for "disabled"
    // while clamping unsafe large values.
    @Test func testFullScreenPreloadRadiusSupportsZeroAndClamps() {
        let (manager, defaults) = makeManager()
        manager.fullScreenPreloadRadius = 0
        #expect(manager.fullScreenPreloadRadius == 0)

        defaults.set(Int.max, forKey: "fullScreenPreloadRadius")
        #expect(manager.fullScreenPreloadRadius == 100)
    }

    // Verifies RAM cache budgets remain bounded so MB-to-bytes conversion
    // remains safe in image cache wrappers.
    @Test func testTimelineRamCacheLimitClamps() {
        let (manager, defaults) = makeManager()
        defaults.set(Int.max, forKey: "maxTimelineThumbnailRAMCacheSizeMB")
        #expect(manager.maxTimelineThumbnailRAMCacheSizeMB == 4096)
    }

    // Verifies disk cache limits and warm counts clamp from outlier values
    // and fall back to defaults for non-positive values.
    @Test func testDiskAndWarmSettingsClampAndFallback() {
        let (manager, defaults) = makeManager()

        defaults.set(Int.max, forKey: "mainDiskCacheLimitMB")
        defaults.set(Int.max, forKey: "topDiskCacheLimitMB")
        defaults.set(Int.max, forKey: "mainCacheWarmItemCount")
        defaults.set(Int.max, forKey: "topCacheWarmItemCount")
        #expect(manager.mainDiskCacheLimitMB == 65536)
        #expect(manager.topDiskCacheLimitMB == 65536)
        #expect(manager.mainCacheWarmItemCount == 100000)
        #expect(manager.topCacheWarmItemCount == 100000)

        defaults.set(0, forKey: "mainDiskCacheLimitMB")
        defaults.set(-1, forKey: "topDiskCacheLimitMB")
        defaults.set(0, forKey: "mainCacheWarmItemCount")
        defaults.set(-5, forKey: "topCacheWarmItemCount")
        #expect(manager.mainDiskCacheLimitMB == 1024)
        #expect(manager.topDiskCacheLimitMB == 100)
        #expect(manager.mainCacheWarmItemCount == 1000)
        #expect(manager.topCacheWarmItemCount == 300)
    }
}

