import Foundation
import Testing
@testable import iosapp

// Tests for CacheSettingsManager to verify cache settings persistence and default values.
@MainActor
struct CacheSettingsManagerTests {
    
    // MARK: - Test Setup/Teardown
    
    func clearCacheSettings() {
        UserDefaults.standard.removeObject(forKey: "cacheImagesBeforeViewport")
        UserDefaults.standard.removeObject(forKey: "cacheImagesAfterViewport")
        UserDefaults.standard.removeObject(forKey: "maxTimelineThumbnailRAMCacheSizeMB")
        UserDefaults.standard.removeObject(forKey: "localThumbnailsEnabled")
        UserDefaults.standard.removeObject(forKey: "fullScreenPreloadRadius")
        UserDefaults.standard.removeObject(forKey: "mainDiskCacheLimitMB")
        UserDefaults.standard.removeObject(forKey: "topDiskCacheLimitMB")
        UserDefaults.standard.removeObject(forKey: "mainCacheWarmItemCount")
        UserDefaults.standard.removeObject(forKey: "topCacheWarmItemCount")
    }
    
    // MARK: - Default Values Tests
    
    @Test func testDefaultValues() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Should default to 100 when no value is set
        #expect(manager.imagesBeforeViewport == 100)
        #expect(manager.imagesAfterViewport == 100)
        #expect(manager.maxTimelineThumbnailRAMCacheSizeMB == 100)
        #expect(manager.localThumbnailsEnabled == true)
    }

    @Test func testLocalThumbnailsEnabledPersists() {
        clearCacheSettings()

        let manager = CacheSettingsManager.shared
        manager.localThumbnailsEnabled = false

        #expect(manager.localThumbnailsEnabled == false)
        #expect(UserDefaults.standard.object(forKey: "localThumbnailsEnabled") as? Bool == false)
    }
    
    @Test func testDefaultValueWhenZero() {
        clearCacheSettings()
        
        // Set to 0 explicitly - should still default to 100
        UserDefaults.standard.set(0, forKey: "cacheImagesBeforeViewport")
        UserDefaults.standard.set(0, forKey: "cacheImagesAfterViewport")
        
        let manager = CacheSettingsManager.shared
        
        // Should default to 100 when value is 0
        #expect(manager.imagesBeforeViewport == 100)
        #expect(manager.imagesAfterViewport == 100)
    }
    
    @Test func testDefaultValueWhenNegative() {
        clearCacheSettings()
        
        // Set to negative value - should default to 100
        UserDefaults.standard.set(-5, forKey: "cacheImagesBeforeViewport")
        UserDefaults.standard.set(-10, forKey: "cacheImagesAfterViewport")
        
        let manager = CacheSettingsManager.shared
        
        // Should default to 100 when value is negative
        #expect(manager.imagesBeforeViewport == 100)
        #expect(manager.imagesAfterViewport == 100)
    }
    
    // MARK: - Persistence Tests
    
    @Test func testSettingBeforeViewport() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Set a custom value
        manager.imagesBeforeViewport = 15
        
        // Verify it's persisted
        #expect(manager.imagesBeforeViewport == 15)
        
        // Verify it's in UserDefaults
        let storedValue = UserDefaults.standard.integer(forKey: "cacheImagesBeforeViewport")
        #expect(storedValue == 15)
    }
    
    @Test func testSettingAfterViewport() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Set a custom value
        manager.imagesAfterViewport = 25
        
        // Verify it's persisted
        #expect(manager.imagesAfterViewport == 25)
        
        // Verify it's in UserDefaults
        let storedValue = UserDefaults.standard.integer(forKey: "cacheImagesAfterViewport")
        #expect(storedValue == 25)
    }
    
    @Test func testSettingBothValues() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Set both values
        manager.imagesBeforeViewport = 10
        manager.imagesAfterViewport = 30
        
        // Verify both are persisted
        #expect(manager.imagesBeforeViewport == 10)
        #expect(manager.imagesAfterViewport == 30)
        
        // Verify both are in UserDefaults
        #expect(UserDefaults.standard.integer(forKey: "cacheImagesBeforeViewport") == 10)
        #expect(UserDefaults.standard.integer(forKey: "cacheImagesAfterViewport") == 30)
    }
    
    @Test func testPersistenceAcrossInstances() {
        clearCacheSettings()
        
        let manager1 = CacheSettingsManager.shared
        manager1.imagesBeforeViewport = 5
        manager1.imagesAfterViewport = 7
        
        // Create a new reference (should be same singleton, but verify persistence)
        let manager2 = CacheSettingsManager.shared
        
        // Both should have the same values
        #expect(manager2.imagesBeforeViewport == 5)
        #expect(manager2.imagesAfterViewport == 7)
    }
    
    @Test func testSettingToZero() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Set to 0
        manager.imagesBeforeViewport = 0
        manager.imagesAfterViewport = 0
        
        // Should be stored as 0 in UserDefaults
        #expect(UserDefaults.standard.integer(forKey: "cacheImagesBeforeViewport") == 0)
        #expect(UserDefaults.standard.integer(forKey: "cacheImagesAfterViewport") == 0)
        
        // But reading should return 100 (default)
        #expect(manager.imagesBeforeViewport == 100)
        #expect(manager.imagesAfterViewport == 100)
    }
    
    @Test func testSettingToLargeValue() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Set to a large value
        manager.imagesBeforeViewport = 100
        manager.imagesAfterViewport = 200
        
        // Should persist large values
        #expect(manager.imagesBeforeViewport == 100)
        #expect(manager.imagesAfterViewport == 200)
    }
    
    @Test func testUpdatingValues() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Set initial values
        manager.imagesBeforeViewport = 10
        manager.imagesAfterViewport = 20
        
        #expect(manager.imagesBeforeViewport == 10)
        #expect(manager.imagesAfterViewport == 20)
        
        // Update values
        manager.imagesBeforeViewport = 15
        manager.imagesAfterViewport = 25
        
        // Should reflect updated values
        #expect(manager.imagesBeforeViewport == 15)
        #expect(manager.imagesAfterViewport == 25)
    }
    
    // MARK: - Edge Cases
    
    @Test func testSettingToMaximumValue() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Set to Int.max (or a very large value)
        manager.imagesBeforeViewport = Int.max
        manager.imagesAfterViewport = Int.max
        
        // Should handle large values
        #expect(manager.imagesBeforeViewport == Int.max)
        #expect(manager.imagesAfterViewport == Int.max)
    }
    
    @Test func testIndependentSettings() {
        clearCacheSettings()
        
        let manager = CacheSettingsManager.shared
        
        // Set different values for before and after
        manager.imagesBeforeViewport = 5
        manager.imagesAfterViewport = 50
        
        // Should maintain independent values
        #expect(manager.imagesBeforeViewport == 5)
        #expect(manager.imagesAfterViewport == 50)
        
        // Changing one shouldn't affect the other
        manager.imagesBeforeViewport = 10
        #expect(manager.imagesBeforeViewport == 10)
        #expect(manager.imagesAfterViewport == 50)
    }

    // MARK: - Fullscreen Preload Radius Tests

    @Test func testFullScreenPreloadRadiusDefault() {
        clearCacheSettings()
        #expect(CacheSettingsManager.shared.fullScreenPreloadRadius == 2)
    }

    @Test func testFullScreenPreloadRadiusSetGet() {
        clearCacheSettings()
        let manager = CacheSettingsManager.shared
        manager.fullScreenPreloadRadius = 5
        #expect(manager.fullScreenPreloadRadius == 5)
        #expect(UserDefaults.standard.integer(forKey: "fullScreenPreloadRadius") == 5)
    }

    @Test func testFullScreenPreloadRadiusZeroPersists() {
        clearCacheSettings()
        let manager = CacheSettingsManager.shared
        manager.fullScreenPreloadRadius = 0
        #expect(manager.fullScreenPreloadRadius == 0)
    }

    // MARK: - Disk Cache Settings

    @Test func testDiskCacheDefaults() {
        clearCacheSettings()
        let manager = CacheSettingsManager.shared
        #expect(manager.mainDiskCacheLimitMB == 1024)
        #expect(manager.topDiskCacheLimitMB == 100)
        #expect(manager.mainCacheWarmItemCount == 1000)
        #expect(manager.topCacheWarmItemCount == 300)
    }

    @Test func testMainDiskCacheLimitPersists() {
        clearCacheSettings()
        let manager = CacheSettingsManager.shared
        manager.mainDiskCacheLimitMB = 2048
        #expect(manager.mainDiskCacheLimitMB == 2048)
        #expect(UserDefaults.standard.integer(forKey: "mainDiskCacheLimitMB") == 2048)
    }

    @Test func testTopDiskCacheLimitPersists() {
        clearCacheSettings()
        let manager = CacheSettingsManager.shared
        manager.topDiskCacheLimitMB = 200
        #expect(manager.topDiskCacheLimitMB == 200)
        #expect(UserDefaults.standard.integer(forKey: "topDiskCacheLimitMB") == 200)
    }

    @Test func testMainCacheWarmItemCountPersists() {
        clearCacheSettings()
        let manager = CacheSettingsManager.shared
        manager.mainCacheWarmItemCount = 500
        #expect(manager.mainCacheWarmItemCount == 500)
        #expect(UserDefaults.standard.integer(forKey: "mainCacheWarmItemCount") == 500)
    }

    @Test func testTopCacheWarmItemCountPersists() {
        clearCacheSettings()
        let manager = CacheSettingsManager.shared
        manager.topCacheWarmItemCount = 150
        #expect(manager.topCacheWarmItemCount == 150)
        #expect(UserDefaults.standard.integer(forKey: "topCacheWarmItemCount") == 150)
    }

    @Test func testDiskCacheDefaultsWhenZeroOrNegative() {
        clearCacheSettings()
        UserDefaults.standard.set(0, forKey: "mainDiskCacheLimitMB")
        UserDefaults.standard.set(-1, forKey: "topDiskCacheLimitMB")
        UserDefaults.standard.set(0, forKey: "mainCacheWarmItemCount")
        UserDefaults.standard.set(-5, forKey: "topCacheWarmItemCount")

        let manager = CacheSettingsManager.shared
        #expect(manager.mainDiskCacheLimitMB == 1024)
        #expect(manager.topDiskCacheLimitMB == 100)
        #expect(manager.mainCacheWarmItemCount == 1000)
        #expect(manager.topCacheWarmItemCount == 300)
    }
}

