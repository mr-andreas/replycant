import Foundation
import Testing
@testable import GitDB
@testable import iosapp

// Verifies timeline sparse-state mutation handling avoids destructive resets on incremental database updates.
@MainActor
struct TimelineManagerDatabaseChangeTests {
    // Binds the manager to a private notification center. Reset and endpoint
    // broadcasts are process-wide and clear the loaded region, so a manager on
    // the default center can be wiped mid-test by an unrelated suite.
    private func makeIsolatedManager() -> TimelineManager {
        TimelineManager(notificationCenter: NotificationCenter())
    }

    // Builds one timeline-visible original fixture with deterministic ordering fields for sparse-window assertions.
    private func makeOriginal(id: String, guessedTakenAt: Date, sha256: String, name: String? = nil) -> OriginalManifest {
        OriginalManifest(
            id: id,
            localID: "local-\(id)",
            sha256: sha256,
            path: "/tmp/\(id).jpg",
            filesize: 1024,
            name: name ?? id,
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
            takenAt: guessedTakenAt,
            guessedTakenAt: guessedTakenAt
        )
    }

    // Builds one thumbnail fixture tied to an originalRef so update-path tests can assert thumbnail replacement behavior.
    private func makeThumbnail(id: String, originalRef: String, sha256: String) -> ThumbnailSetManifest {
        ThumbnailSetManifest(
            originalRef: originalRef,
            thumbnails: [
                .init(name: id, sha256: sha256, width: 50, height: 50, filesize: 256),
            ],
            name: "\(id)-set",
            deviceSpace: "device-a"
        )
    }

    // Produces the canonical originalRef key used by TimelineManager thumbnail lookups.
    private func originalRef(for original: OriginalManifest) -> String {
        "\(original.metadata.deviceSpace)/media.replycant.com/v1alpha1/Original/\(original.metadata.name)"
    }

    // Ensures incremental additions keep already-loaded sparse items in memory instead of clearing the window.
    @Test func incrementalAdditionKeepsLoadedItems() {
        let manager = makeIsolatedManager()
        let first = makeOriginal(id: "a", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "sha-a")
        let second = makeOriginal(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "sha-b")
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [TimelineItem(original: first), TimelineItem(original: second)],
            totalCount: 2
        )

        let added = makeOriginal(id: "c", guessedTakenAt: Date(timeIntervalSince1970: 30), sha256: "sha-c")
        manager.applyDatabaseChange(
            .incremental(ManifestMutation(added: [added], updated: [], removed: [])),
            refreshedTotalCount: 3
        )

        #expect(manager.loadedItems.map(\.id) == ["a", "b"])
        #expect(manager.totalCount == 3)
    }

    // Ensures additions that sort before the sparse window shift loaded offset so global indices stay aligned.
    @Test func incrementalAdditionBeforeWindowAdjustsOffset() {
        let manager = makeIsolatedManager()
        let windowFirst = makeOriginal(id: "c", guessedTakenAt: Date(timeIntervalSince1970: 30), sha256: "sha-c")
        let windowSecond = makeOriginal(id: "d", guessedTakenAt: Date(timeIntervalSince1970: 40), sha256: "sha-d")
        manager.seedLoadedRegionForTesting(
            offset: 2,
            items: [TimelineItem(original: windowFirst), TimelineItem(original: windowSecond)],
            totalCount: 4
        )

        let addedBefore = makeOriginal(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "sha-b")
        manager.applyDatabaseChange(
            .incremental(ManifestMutation(added: [addedBefore], updated: [], removed: [])),
            refreshedTotalCount: 5
        )

        #expect(manager.item(at: 2) == nil)
        #expect(manager.item(at: 3)?.id == "c")
        #expect(manager.item(at: 4)?.id == "d")
        #expect(manager.loadedItems.map(\.id) == ["c", "d"])
        #expect(manager.totalCount == 5)
    }

    // Ensures additions that sort inside the sparse window are inserted in-memory in chronological order.
    @Test func incrementalAdditionWithinWindowInsertsInOrder() {
        let manager = makeIsolatedManager()
        let first = makeOriginal(id: "a", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "sha-a")
        let third = makeOriginal(id: "c", guessedTakenAt: Date(timeIntervalSince1970: 30), sha256: "sha-c")
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [TimelineItem(original: first), TimelineItem(original: third)],
            totalCount: 2
        )

        let second = makeOriginal(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "sha-b")
        manager.applyDatabaseChange(
            .incremental(ManifestMutation(added: [second], updated: [], removed: [])),
            refreshedTotalCount: 3
        )

        #expect(manager.loadedItems.map(\.id) == ["a", "b", "c"])
        #expect(manager.item(at: 0)?.id == "a")
        #expect(manager.item(at: 1)?.id == "b")
        #expect(manager.item(at: 2)?.id == "c")
    }

    // Ensures mixed additions across before/within/after regions preserve offset and only insert in-window rows.
    @Test func mixedIncrementalAdditionsMaintainWindowAlignment() {
        let manager = makeIsolatedManager()
        let first = makeOriginal(id: "c", guessedTakenAt: Date(timeIntervalSince1970: 30), sha256: "sha-c")
        let third = makeOriginal(id: "e", guessedTakenAt: Date(timeIntervalSince1970: 50), sha256: "sha-e")
        manager.seedLoadedRegionForTesting(
            offset: 2,
            items: [TimelineItem(original: first), TimelineItem(original: third)],
            totalCount: 6
        )

        let beforeWindow = makeOriginal(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "sha-b")
        let withinWindow = makeOriginal(id: "d", guessedTakenAt: Date(timeIntervalSince1970: 40), sha256: "sha-d")
        let afterWindow = makeOriginal(id: "f", guessedTakenAt: Date(timeIntervalSince1970: 60), sha256: "sha-f")
        manager.applyDatabaseChange(
            .incremental(
                ManifestMutation(
                    added: [beforeWindow, withinWindow, afterWindow],
                    updated: [],
                    removed: []
                )
            ),
            refreshedTotalCount: 9
        )

        #expect(manager.loadedItems.map(\.id) == ["c", "d", "e"])
        #expect(manager.item(at: 2) == nil)
        #expect(manager.item(at: 3)?.id == "c")
        #expect(manager.item(at: 4)?.id == "d")
        #expect(manager.item(at: 5)?.id == "e")
    }

    // Ensures off-window additions do not trigger visible-cell reconfiguration work.
    @Test func offWindowIncrementalAdditionDoesNotBumpLoadGeneration() {
        let manager = makeIsolatedManager()
        let first = makeOriginal(id: "a", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "sha-a")
        let second = makeOriginal(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "sha-b")
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [TimelineItem(original: first), TimelineItem(original: second)],
            totalCount: 2
        )
        let generationBefore = manager.loadGeneration

        let added = makeOriginal(id: "c", guessedTakenAt: Date(timeIntervalSince1970: 30), sha256: "sha-c")
        manager.applyDatabaseChange(
            .incremental(ManifestMutation(added: [added], updated: [], removed: [])),
            refreshedTotalCount: 3
        )

        #expect(manager.loadGeneration == generationBefore)
    }

    // Ensures incremental removals drop affected loaded entries and preserve global index alignment via offset adjustment.
    @Test func incrementalRemovalAdjustsWindowAndOffset() {
        let manager = makeIsolatedManager()
        let oldest = makeOriginal(id: "a", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "sha-a")
        let inWindowFirst = makeOriginal(id: "c", guessedTakenAt: Date(timeIntervalSince1970: 30), sha256: "sha-c")
        let inWindowSecond = makeOriginal(id: "d", guessedTakenAt: Date(timeIntervalSince1970: 40), sha256: "sha-d")
        manager.seedLoadedRegionForTesting(
            offset: 2,
            items: [TimelineItem(original: inWindowFirst), TimelineItem(original: inWindowSecond)],
            totalCount: 4
        )

        manager.applyDatabaseChange(
            .incremental(
                ManifestMutation(
                    added: [],
                    updated: [],
                    removed: [oldest, inWindowFirst]
                )
            ),
            refreshedTotalCount: 2
        )

        #expect(manager.loadedItems.map(\.id) == ["d"])
        #expect(manager.item(at: 1)?.id == "d")
        #expect(manager.item(at: 0) == nil)
        #expect(manager.totalCount == 2)
    }

    // Ensures incremental updates replace loaded originals and refreshed thumbnails in-place without clearing the window.
    @Test func incrementalUpdateReplacesLoadedItemInPlace() {
        let manager = makeIsolatedManager()
        let original = makeOriginal(id: "x", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "sha-old")
        let thumbOld = makeThumbnail(id: "x-thumb", originalRef: originalRef(for: original), sha256: "thumb-old")
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [TimelineItem(original: original, thumbnail: thumbOld)],
            totalCount: 1
        )

        let updated = makeOriginal(
            id: "x",
            guessedTakenAt: Date(timeIntervalSince1970: 10),
            sha256: "sha-new",
            name: "x-renamed"
        )
        let thumbNew = makeThumbnail(id: "x-thumb-new", originalRef: originalRef(for: updated), sha256: "thumb-new")
        manager.applyDatabaseChange(
            .incremental(
                ManifestMutation(
                    added: [],
                    updated: [updated, thumbNew],
                    removed: []
                )
            ),
            refreshedTotalCount: 1
        )

        #expect(manager.loadedItems.count == 1)
        #expect(manager.loadedItems[0].id == "x")
        #expect(manager.loadedItems[0].original.spec.sha256 == "sha-new")
        #expect(manager.loadedItems[0].thumbnail?.spec.thumbnails.first?.sha256 == "thumb-new")
    }

    // Ensures loaded thumbnail updates bump generation so visible cells can reconfigure without full reload.
    @Test func loadedThumbnailUpdateBumpsLoadGeneration() {
        let manager = makeIsolatedManager()
        let original = makeOriginal(id: "x", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "sha-old")
        let thumbOld = makeThumbnail(id: "x-thumb", originalRef: originalRef(for: original), sha256: "thumb-old")
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [TimelineItem(original: original, thumbnail: thumbOld)],
            totalCount: 1
        )
        let generationBefore = manager.loadGeneration

        let thumbNew = makeThumbnail(id: "x-thumb-new", originalRef: originalRef(for: original), sha256: "thumb-new")
        manager.applyDatabaseChange(
            .incremental(ManifestMutation(added: [], updated: [thumbNew], removed: [])),
            refreshedTotalCount: 1
        )

        #expect(manager.loadGeneration == generationBefore + 1)
        #expect(manager.loadedItems[0].thumbnail?.spec.thumbnails.first?.sha256 == "thumb-new")
    }

    // Ensures full-replace events keep destructive reset behavior so clone/resync flows do not leave stale sparse state.
    @Test func fullReplaceStillClearsSparseState() {
        let manager = makeIsolatedManager()
        let first = makeOriginal(id: "a", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "sha-a")
        let second = makeOriginal(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "sha-b")
        manager.seedLoadedRegionForTesting(
            offset: 0,
            items: [TimelineItem(original: first), TimelineItem(original: second)],
            totalCount: 2
        )

        manager.applyDatabaseChange(.fullReplace, refreshedTotalCount: 5)

        #expect(manager.loadedItems.isEmpty)
        #expect(manager.item(at: 0) == nil)
        #expect(manager.totalCount == 5)
    }
}
