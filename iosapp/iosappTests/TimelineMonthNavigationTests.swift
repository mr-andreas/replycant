import Foundation
import Testing
import Combine
@testable import GitDB
@testable import iosapp

// Verifies month-sidebar indexing logic maps grouped month data to stable jump targets.
@MainActor
struct TimelineMonthNavigationTests {
    // Produces timeline originals with deterministic takenAt values so month-resolution tests can exercise date bucketing.
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

    // Waits until the manager publishes the expected month so assertions can
    // observe async main-actor publication even under contended CI runners.
    private func waitForMonth(
        _ expected: TimelineYearMonth,
        manager: TimelineManager,
        attempts: Int = 100,
        sleepNanoseconds: UInt64 = 20_000_000
    ) async throws {
        var tries = 0
        while tries < attempts && manager.currentYearMonth != expected {
            tries += 1
            try await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        #expect(manager.currentYearMonth == expected)
    }

    // Counts objectWillChange emissions while executing a synchronous action.
    private func countObjectWillChange<T: ObservableObject>(
        of object: T,
        during action: () -> Void
    ) -> Int {
        var count = 0
        let cancellable = object.objectWillChange.sink { _ in
            count += 1
        }
        action()
        cancellable.cancel()
        return count
    }

    // Ensures month counts are transformed into cumulative offsets used for top-aligned month jumps.
    @Test func monthEntriesUseCumulativeOffsets() {
        let entries = TimelineManager.monthEntries(from: [
            TimelineMonthCount(year: 2024, month: 1, count: 3),
            TimelineMonthCount(year: 2024, month: 2, count: 5),
            TimelineMonthCount(year: 2024, month: 4, count: 2),
        ])

        #expect(entries.count == 3)
        #expect(entries[0].year == 2024 && entries[0].month == 1 && entries[0].globalOffset == 0)
        #expect(entries[1].year == 2024 && entries[1].month == 2 && entries[1].globalOffset == 3)
        #expect(entries[2].year == 2024 && entries[2].month == 4 && entries[2].globalOffset == 8)
    }

    // Ensures sidebar display sections keep years/months sorted while precomputing stable labels and ids.
    @Test func sidebarSectionsUseSortedYearsMonthsAndStableLabels() {
        let sections = TimelineMonthSidebarSection.sections(from: [
            TimelineMonthEntry(yearMonth: TimelineYearMonth(year: 2025, month: 3), count: 1, globalOffset: 10),
            TimelineMonthEntry(yearMonth: TimelineYearMonth(year: 2024, month: 12), count: 2, globalOffset: 8),
            TimelineMonthEntry(yearMonth: TimelineYearMonth(year: 2025, month: 1), count: 4, globalOffset: 0),
        ])

        #expect(sections.map(\.year) == [2024, 2025])
        #expect(sections[0].entries.map(\.month) == [12])
        #expect(sections[1].entries.map(\.month) == [1, 3])
        #expect(sections[1].entries.map(\.id) == ["2025-1", "2025-3"])
        #expect(!sections[1].entries[0].label.isEmpty)
    }

    // Ensures selecting one month publishes the matching global target index for coordinator-driven collection scrolling.
    @Test func scrollToMonthPublishesTargetIndex() async throws {
        let manager = TimelineManager()
        manager.seedMonthIndexForTesting([
            TimelineMonthCount(year: 2024, month: 1, count: 2),
            TimelineMonthCount(year: 2024, month: 2, count: 4),
            TimelineMonthCount(year: 2024, month: 3, count: 1),
        ])

        manager.scrollToMonth(year: 2024, month: 2)

        var attempts = 0
        while attempts < 10 && manager.scrollTargetIndex == nil {
            attempts += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(manager.currentYearMonth == TimelineYearMonth(year: 2024, month: 2))
        #expect(manager.scrollTargetIndex == 2)
    }

    // Ensures viewport updates do not clear month selection when sparse loading temporarily has no top visible item.
    @Test func updateCurrentMonthDoesNotClearSelectionWhenIndexUnavailable() {
        let manager = TimelineManager()
        manager.seedMonthIndexForTesting([
            TimelineMonthCount(year: 2024, month: 1, count: 2),
            TimelineMonthCount(year: 2024, month: 2, count: 4),
        ])
        manager.scrollToMonth(year: 2024, month: 2)

        manager.updateCurrentMonth(for: nil)

        #expect(manager.currentYearMonth == TimelineYearMonth(year: 2024, month: 2))
    }

    // Builds a date firmly inside year/month for every runner timezone so
    // Calendar.current month extraction matches production updateCurrentMonth.
    private func dateInMonth(year: Int, month: Int, day: Int = 15) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    // Ensures rapid month updates are rate-limited so sidebar selection does not churn during fast scroll callbacks.
    @Test func updateCurrentMonthThrottlesRapidChanges() async throws {
        let manager = TimelineManager()
        let januaryDate = dateInMonth(year: 2024, month: 1)
        let februaryDate = dateInMonth(year: 2024, month: 2)
        let january = TimelineYearMonth(year: 2024, month: 1)
        let february = TimelineYearMonth(year: 2024, month: 2)
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [
                TimelineItem(original: makeOriginal(id: "jan-item", takenAt: januaryDate)),
                TimelineItem(original: makeOriginal(id: "feb-item", takenAt: februaryDate))
            ],
            totalCount: 2
        )

        manager.updateCurrentMonth(for: 0)
        try await waitForMonth(january, manager: manager)

        manager.updateCurrentMonth(for: 1)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(manager.currentYearMonth == january)

        try await Task.sleep(nanoseconds: 550_000_000)
        manager.updateCurrentMonth(for: 1)
        try await waitForMonth(february, manager: manager)
    }

    // Ensures the latest month selection is flushed when scrolling settles so sidebar and viewport end in sync.
    @Test func setGridScrollingFalseFlushesPendingMonthUpdate() async throws {
        let manager = TimelineManager()
        let januaryDate = dateInMonth(year: 2024, month: 1)
        let februaryDate = dateInMonth(year: 2024, month: 2)
        let january = TimelineYearMonth(year: 2024, month: 1)
        let february = TimelineYearMonth(year: 2024, month: 2)
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [
                TimelineItem(original: makeOriginal(id: "jan-item", takenAt: januaryDate)),
                TimelineItem(original: makeOriginal(id: "feb-item", takenAt: februaryDate))
            ],
            totalCount: 2
        )

        manager.setGridScrolling(true)
        manager.updateCurrentMonth(for: 0)
        try await waitForMonth(january, manager: manager)

        manager.updateCurrentMonth(for: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.currentYearMonth == january)

        manager.setGridScrolling(false)
        try await waitForMonth(february, manager: manager)
    }

    // Ensures month sidebar sections are precomputed with month index changes and remain stable across viewport month updates.
    @Test func managerPublishesMonthSidebarSectionsFromMonthIndexChanges() {
        let manager = TimelineManager()
        manager.seedMonthIndexForTesting([
            TimelineMonthCount(year: 2024, month: 1, count: 2),
            TimelineMonthCount(year: 2024, month: 2, count: 1),
            TimelineMonthCount(year: 2025, month: 3, count: 5),
        ])

        let initialSections = manager.monthSidebarSections
        #expect(initialSections.map(\.year) == [2024, 2025])
        #expect(initialSections[0].entries.map(\.id) == ["2024-1", "2024-2"])
        #expect(initialSections[1].entries.map(\.id) == ["2025-3"])

        let januaryDate = dateInMonth(year: 2024, month: 1)
        let februaryDate = dateInMonth(year: 2024, month: 2)
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [
                TimelineItem(original: makeOriginal(id: "jan-item", takenAt: januaryDate)),
                TimelineItem(original: makeOriginal(id: "feb-item", takenAt: februaryDate))
            ],
            totalCount: 2
        )

        manager.updateCurrentMonth(for: 0, force: true)
        manager.updateCurrentMonth(for: 1, force: true)
        #expect(manager.monthSidebarSections == initialSections)
    }

    // Ensures row equality depends only on rendered identity and highlight state, not tap closure identity.
    @Test func monthRowEqualityIgnoresClosureAndTracksHighlight() {
        let a = TimelineMonthRow(
            id: "2024-1",
            label: "Jan",
            isHighlighted: false,
            onTap: {}
        )
        let b = TimelineMonthRow(
            id: "2024-1",
            label: "Jan",
            isHighlighted: false,
            onTap: { _ = 1 + 1 }
        )
        let c = TimelineMonthRow(
            id: "2024-1",
            label: "Jan",
            isHighlighted: true,
            onTap: {}
        )

        #expect(a == b)
        #expect(a != c)
    }

    // Ensures month updates invalidate only the month-selection model, not the full timeline manager.
    @Test func monthUpdatesDoNotEmitManagerObjectWillChange() {
        let manager = TimelineManager()
        manager.seedMonthIndexForTesting([
            TimelineMonthCount(year: 2024, month: 1, count: 2),
            TimelineMonthCount(year: 2024, month: 2, count: 1),
        ])
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [
                TimelineItem(original: makeOriginal(id: "jan-item", takenAt: dateInMonth(year: 2024, month: 1))),
                TimelineItem(original: makeOriginal(id: "feb-item", takenAt: dateInMonth(year: 2024, month: 2)))
            ],
            totalCount: 3
        )

        let managerChanges = countObjectWillChange(of: manager) {
            manager.updateCurrentMonth(for: 0, force: true)
            manager.updateCurrentMonth(for: 1, force: true)
            manager.setGridScrolling(true)
            manager.setGridScrolling(false)
        }
        let selectionChanges = countObjectWillChange(of: manager.monthSelection) {
            manager.updateCurrentMonth(for: 0, force: true)
            manager.updateCurrentMonth(for: 1, force: true)
            manager.setGridScrolling(true)
            manager.setGridScrolling(false)
        }

        #expect(managerChanges == 0)
        #expect(selectionChanges > 0)
    }

    // Ensures paging-window mutations do not invalidate the month-selection model.
    @Test func loadedRegionSeedDoesNotEmitMonthSelectionObjectWillChange() {
        let manager = TimelineManager()
        manager.seedMonthIndexForTesting([
            TimelineMonthCount(year: 2024, month: 1, count: 2),
        ])

        let selectionChanges = countObjectWillChange(of: manager.monthSelection) {
            manager.seedLoadedRegionForTesting(
                offset: 0,
                items: [
                    TimelineItem(original: makeOriginal(id: "a", takenAt: Date(timeIntervalSince1970: 10))),
                    TimelineItem(original: makeOriginal(id: "b", takenAt: Date(timeIntervalSince1970: 20))),
                ],
                totalCount: 2
            )
        }

        #expect(selectionChanges == 0)
    }

    // Ensures load-generation transitions are observable through the dedicated publisher after removing @Published loadGeneration.
    @Test func loadGenerationPublisherEmitsWhenGenerationIncrements() {
        let manager = TimelineManager()
        let original = makeOriginal(id: "x", takenAt: Date(timeIntervalSince1970: 10))
        let thumbnailOld = ThumbnailSetManifest(
            originalRef: "\(original.metadata.deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)",
            thumbnails: [.init(name: "t-old", sha256: "thumb-old", width: 64, height: 64, filesize: 128)],
            name: "thumb-old-set",
            deviceSpace: original.metadata.deviceSpace
        )
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [TimelineItem(original: original, thumbnail: thumbnailOld)],
            totalCount: 1
        )

        var emissions: [Int] = []
        let cancellable = manager.loadGenerationPublisher.sink { value in
            emissions.append(value)
        }
        let thumbnailNew = ThumbnailSetManifest(
            originalRef: thumbnailOld.spec.originalRef,
            thumbnails: [.init(name: "t-new", sha256: "thumb-new", width: 64, height: 64, filesize: 128)],
            name: "thumb-new-set",
            deviceSpace: original.metadata.deviceSpace
        )
        manager.applyDatabaseChange(
            .incremental(ManifestMutation(added: [], updated: [thumbnailNew], removed: [])),
            refreshedTotalCount: 1
        )
        cancellable.cancel()

        #expect(emissions.last == manager.loadGeneration)
        #expect(!emissions.isEmpty)
    }
}
