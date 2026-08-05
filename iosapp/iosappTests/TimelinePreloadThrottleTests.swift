import Foundation
import Testing
@testable import GitDB
@testable import iosapp

/// Verifies that rapid cell appear/disappear calls during scrolling
/// are coalesced into a single preload pass rather than triggering
/// expensive O(200) iteration on every callback.
@Suite("Timeline Preload Throttle Tests", .serialized)
@MainActor
struct TimelinePreloadThrottleTests {
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

    private func makeItems(count: Int) -> [TimelineItem] {
        (0..<count).map { i in
            let date = Date(timeIntervalSince1970: Double(i) * 86400)
            return TimelineItem(original: makeOriginal(id: "item-\(i)", takenAt: date))
        }
    }

    /// Pins viewport preload counts so other suites that mutate
    /// CacheSettingsManager.shared cannot shrink the window to empty.
    private func ensurePreloadWindow() {
        CacheSettingsManager.shared.imagesBeforeViewport = 100
        CacheSettingsManager.shared.imagesAfterViewport = 100
    }

    /// Preload does not fire synchronously — rapid appear calls are
    /// coalesced via a trailing-edge debounce.
    @Test func preloadIsNotImmediateAfterAppear() {
        ensurePreloadWindow()
        let manager = TimelineManager()
        let items = makeItems(count: 20)
        manager.seedLoadedRegionForTesting(offset: 0, items: items, totalCount: 20)

        for i in 0..<9 {
            manager.itemDidAppear(at: i)
        }

        // Immediately after appear calls, preload should NOT have fired
        // (item at index 15 is outside the 9-cell viewport but within
        // the preload window — it should not be marked yet).
        #expect(manager.shouldPreloadItem(at: 15) == false)
    }

    /// After the coalesced preload pass runs, items within the
    /// configured preload range become eligible.
    @Test func preloadFiresAfterDebounceWindow() {
        ensurePreloadWindow()
        let manager = TimelineManager()
        let items = makeItems(count: 20)
        manager.seedLoadedRegionForTesting(offset: 0, items: items, totalCount: 20)

        for i in 0..<9 {
            manager.itemDidAppear(at: i)
        }

        #expect(manager.shouldPreloadItem(at: 12) == false)
        // Flush instead of sleeping: CI MainActor contention can delay
        // the trailing Task far beyond any fixed wait budget.
        manager.flushPreloadUpdateForTesting()
        #expect(manager.shouldPreloadItem(at: 12) == true)
    }

    /// Multiple rapid appear/disappear cycles result in only one
    /// final preload pass reflecting the last stable viewport state.
    @Test func rapidAppearDisappearCoalescesIntoOnePass() {
        ensurePreloadWindow()
        let manager = TimelineManager()
        let items = makeItems(count: 50)
        manager.seedLoadedRegionForTesting(offset: 0, items: items, totalCount: 50)

        // Simulate fast scroll: cells 0-8 appear then disappear,
        // then cells 9-17 appear
        for i in 0..<9 { manager.itemDidAppear(at: i) }
        for i in 0..<9 { manager.itemDidDisappear(at: i) }
        for i in 9..<18 { manager.itemDidAppear(at: i) }

        // Immediately: no preload from the old viewport range
        #expect(manager.shouldPreloadItem(at: 3) == false)

        manager.flushPreloadUpdateForTesting()

        // After the coalesced pass, preload reflects the final viewport
        // (9-17), not the initial one (0-8).
        #expect(manager.shouldPreloadItem(at: 3) == true)
        #expect(manager.shouldPreloadItem(at: 25) == true)
    }

    /// While grid is actively scrolling, preload scheduling is fully
    /// suppressed — no debounce timer fires.
    @Test func preloadSuppressedDuringActiveScroll() async throws {
        ensurePreloadWindow()
        let manager = TimelineManager()
        let items = makeItems(count: 30)
        manager.seedLoadedRegionForTesting(offset: 0, items: items, totalCount: 30)

        manager.setGridScrolling(true)
        for i in 0..<9 { manager.itemDidAppear(at: i) }

        // Wait well past the debounce window; scrolling skips scheduling.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(manager.shouldPreloadItem(at: 15) == false)
    }

    /// When scrolling ends, preload fires immediately without waiting
    /// for the debounce delay.
    @Test func preloadFiresImmediatelyWhenScrollingEnds() {
        ensurePreloadWindow()
        let manager = TimelineManager()
        let items = makeItems(count: 30)
        manager.seedLoadedRegionForTesting(offset: 0, items: items, totalCount: 30)

        manager.setGridScrolling(true)
        for i in 0..<9 { manager.itemDidAppear(at: i) }

        // End scrolling — preload should fire synchronously
        manager.setGridScrolling(false)

        // Preload should now be populated
        #expect(manager.shouldPreloadItem(at: 15) == true)
    }
}
