import Foundation
import Testing
@testable import GitDB
@testable import iosapp

/// Guards against timeline preload arithmetic traps when persisted
/// cache settings contain outlier values.
@MainActor
struct TimelinePreloadOverflowTests {
    // Uses a private notification center so unrelated suites cannot
    // mutate this manager's loaded-region state during the test.
    private func makeIsolatedManager() -> TimelineManager {
        TimelineManager(notificationCenter: NotificationCenter())
    }

    // Builds a stable synthetic manifest so preload checks can
    // exercise index math without repository wiring.
    private func makeOriginal(id: String, takenAt: Date) -> OriginalManifest {
        OriginalManifest(
            id: id,
            localID: "local-\(id)",
            sha256: "sha-\(id)",
            path: "/tmp/\(id).jpg",
            filesize: 1024,
            name: id,
            deviceSpace: "device-a",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            takenAt: takenAt,
            guessedTakenAt: takenAt
        )
    }

    // Seeds timeline items with deterministic IDs so preload
    // membership can be asserted by index.
    private func makeItems(count: Int) -> [TimelineItem] {
        (0..<count).map { index in
            let date = Date(timeIntervalSince1970: Double(index) * 86400)
            return TimelineItem(original: makeOriginal(id: "item-\(index)", takenAt: date))
        }
    }

    // Verifies the preload pass no longer traps when poisoned defaults
    // hold Int.max and still expands to the full available range.
    @Test func preloadRangeHandlesIntMaxSettingsWithoutOverflow() {
        let beforeKey = "cacheImagesBeforeViewport"
        let afterKey = "cacheImagesAfterViewport"
        UserDefaults.standard.set(Int.max, forKey: beforeKey)
        UserDefaults.standard.set(Int.max, forKey: afterKey)
        defer {
            UserDefaults.standard.removeObject(forKey: beforeKey)
            UserDefaults.standard.removeObject(forKey: afterKey)
        }

        let manager = makeIsolatedManager()
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: makeItems(count: 20),
            totalCount: 20
        )

        manager.setGridScrolling(true)
        for index in 8...10 {
            manager.itemDidAppear(at: index)
        }

        // setGridScrolling(false) forces a synchronous preload pass.
        manager.setGridScrolling(false)

        #expect(manager.shouldPreloadItem(at: 0))
        #expect(manager.shouldPreloadItem(at: 19))
    }
}
