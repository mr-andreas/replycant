import Foundation
import Testing
@testable import GitDB
@testable import iosapp

/// Verifies that rapid cell appear/disappear calls during scrolling
/// are coalesced into a single preload pass rather than triggering
/// expensive O(200) iteration on every callback.
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

    /// Polls until preload marks an index, absorbing MainActor scheduling
    /// jitter that makes a single fixed sleep unreliable on CI.
    private func waitForPreload(
        _ manager: TimelineManager,
        index: Int,
        attempts: Int = 50,
        sleepNanoseconds: UInt64 = 20_000_000
    ) async throws {
        var tries = 0
        while tries < attempts && !manager.shouldPreloadItem(at: index) {
            tries += 1
            try await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        #expect(manager.shouldPreloadItem(at: index) == true)
    }

    /// Preload does not fire synchronously — rapid appear calls are
    /// coalesced via a trailing-edge debounce.
    @Test func preloadIsNotImmediateAfterAppear() {
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

    /// After the debounce window elapses, the preload pass runs and
    /// items within the configured preload range become eligible.
    @Test func preloadFiresAfterDebounceWindow() async throws {
        let manager = TimelineManager()
        let items = makeItems(count: 20)
        manager.seedLoadedRegionForTesting(offset: 0, items: items, totalCount: 20)

        for i in 0..<9 {
            manager.itemDidAppear(at: i)
        }

        // Poll past the 150ms debounce; CI MainActor contention can delay
        // the trailing Task beyond a single fixed sleep.
        try await waitForPreload(manager, index: 12)
    }

    /// Multiple rapid appear/disappear cycles result in only one
    /// final preload pass reflecting the last stable viewport state.
    @Test func rapidAppearDisappearCoalescesIntoOnePass() async throws {
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

        // After debounce, preload reflects the final viewport (9-17),
        // not the initial one (0-8). Items before viewport 9 should
        // be preloaded (within beforeViewport range), and items at
        // index 3 should be eligible since default beforeViewport=100.
        try await waitForPreload(manager, index: 3)
        try await waitForPreload(manager, index: 25)
    }

    /// While grid is actively scrolling, preload scheduling is fully
    /// suppressed — no debounce timer fires.
    @Test func preloadSuppressedDuringActiveScroll() async throws {
        let manager = TimelineManager()
        let items = makeItems(count: 30)
        manager.seedLoadedRegionForTesting(offset: 0, items: items, totalCount: 30)

        manager.setGridScrolling(true)
        for i in 0..<9 { manager.itemDidAppear(at: i) }

        // Wait well past the debounce window
        try await Task.sleep(nanoseconds: 300_000_000)

        // Preload should NOT have fired — scrolling suppresses it
        #expect(manager.shouldPreloadItem(at: 15) == false)
    }

    /// When scrolling ends, preload fires immediately without waiting
    /// for the debounce delay.
    @Test func preloadFiresImmediatelyWhenScrollingEnds() {
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
