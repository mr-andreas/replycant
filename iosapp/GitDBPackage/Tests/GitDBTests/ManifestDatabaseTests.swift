import Foundation
import Combine
import Testing
@testable import GitDB

// Verifies registration-driven SQLite storage semantics and generic query behavior.
@MainActor
struct ManifestDatabaseTests {
    // Creates a database rooted in a temporary file so each test gets isolated schema state.
    private func makeDatabase() throws -> (ManifestDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-db-\(UUID().uuidString).sqlite")
        let database = try ManifestDatabase(databaseURL: url, registry: makeTestRegistry())
        return (database, url)
    }

    // Waits for the next database change while executing a mutation to validate emitted payloads.
    private func captureNextChange(
        from database: ManifestDatabase,
        perform operation: @escaping () async throws -> Void
    ) async throws -> ManifestDatabaseChange {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            var resumed = false
            cancellable = database.changes.sink { change in
                guard !resumed else { return }
                resumed = true
                cancellable?.cancel()
                continuation.resume(returning: change)
            }
            Task {
                do {
                    try await operation()
                } catch {
                    guard !resumed else { return }
                    resumed = true
                    cancellable?.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Ensures count/query behavior works on registered columns.
    @Test func queryCountAndTimelineOrdering() async throws {
        let (database, _) = try makeDatabase()
        let originals: [any Manifest] = [
            TestOriginalManifest(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "s1"),
            TestOriginalManifest(id: "a", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "s2"),
            TestOriginalManifest(id: "c", guessedTakenAt: nil, sha256: "s3"),
            TestOriginalManifest(id: "d", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "s4"),
        ]
        try await database.applyMutation(added: originals, updated: [], removed: [], commitHash: "c1")
        let table = try await database.tableName(for: TestOriginalManifest.self)
        let lowerBound = 0.0
        let count = try await database.queryCount(sql: """
            SELECT COUNT(*)
            FROM \(table)
            WHERE guessedTakenAt IS NOT NULL AND guessedTakenAt > ?
        """, arguments: [lowerBound])
        #expect(count == 3)
        let limit = 2
        let offset = 0
        let page = try await database.query(TestOriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE guessedTakenAt IS NOT NULL
            ORDER BY guessedTakenAt ASC, id ASC
            LIMIT ? OFFSET ?
        """, arguments: [limit, offset])
        #expect(page.map(\.id) == ["d", "a"])
    }

    // Ensures batch thumbnail lookup can be implemented through generic query APIs.
    @Test func thumbnailQueryByOriginalRef() async throws {
        let (database, _) = try makeDatabase()
        let thumbs: [any Manifest] = [
            TestThumbnailSetManifest(id: "t1", originalRef: "ref-a"),
            TestThumbnailSetManifest(id: "t2", originalRef: "ref-b"),
        ]
        try await database.applyMutation(added: thumbs, updated: [], removed: [], commitHash: "c1")
        let table = try await database.tableName(for: TestThumbnailSetManifest.self)
        let ref = "ref-a"
        let rows = try await database.query(TestThumbnailSetManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE originalRef IN (?)
        """, arguments: [ref])
        #expect(rows.map(\.id) == ["t1"])
    }

    // Verifies incremental mutations publish generic added/updated/removed payloads.
    @Test func applyMutationPublishesIncremental() async throws {
        let (database, _) = try makeDatabase()
        let old = TestOriginalManifest(id: "img-old", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "old-sha")
        let new = TestOriginalManifest(id: "img-new", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "new-sha")
        try await database.applyMutation(added: [old], updated: [], removed: [], commitHash: "c1")

        let change = try await captureNextChange(from: database, perform: {
            try await database.applyMutation(
                added: [new],
                updated: [],
                removed: [old],
                commitHash: "c2"
            )
        })

        switch change {
        case .fullReplace:
            #expect(false)
        case .incremental(let mutation):
            #expect(mutation.added.count == 1)
            #expect(mutation.added.first?.id == new.id)
            #expect(mutation.updated.isEmpty)
            #expect(mutation.removed.count == 1)
            #expect(mutation.removed.first?.id == old.id)
            #expect((mutation.removed.first as? TestOriginalManifest)?.spec.sha256 == old.spec.sha256)
        }
        #expect(try await database.readSyncedCommitHash() == "c2")
    }

    // Verifies upserts of existing rows emit updated (not added) mutations.
    @Test func applyMutationPublishesUpdated() async throws {
        let (database, _) = try makeDatabase()
        let old = TestOriginalManifest(id: "img-a", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "sha-old")
        let replacement = TestOriginalManifest(id: "img-a", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "sha-new")
        try await database.applyMutation(added: [old], updated: [], removed: [], commitHash: "c1")

        let change = try await captureNextChange(from: database, perform: {
            try await database.applyMutation(
                added: [],
                updated: [replacement],
                removed: [],
                commitHash: "c2"
            )
        })

        switch change {
        case .fullReplace:
            #expect(false)
        case .incremental(let mutation):
            #expect(mutation.added.isEmpty)
            #expect(mutation.updated.count == 1)
            #expect(mutation.updated.first?.id == replacement.id)
            #expect((mutation.updated.first as? TestOriginalManifest)?.spec.sha256 == replacement.spec.sha256)
            #expect(mutation.removed.isEmpty)
        }
    }

    // Verifies replaceAll and clearAll publish fullReplace events.
    @Test func replaceAllAndClearAllPublishFullReplace() async throws {
        let (database, _) = try makeDatabase()
        let manifest = TestOriginalManifest(id: "img-1", guessedTakenAt: Date(), sha256: "sha-1")

        let replaceChange = try await captureNextChange(from: database, perform: {
            try await database.replaceAll(manifests: [manifest], commitHash: "commit-a")
        })
        if case .fullReplace = replaceChange {
            #expect(true)
        } else {
            #expect(false)
        }

        let clearChange = try await captureNextChange(from: database, perform: {
            try await database.clearAll()
        })
        if case .fullReplace = clearChange {
            #expect(true)
        } else {
            #expect(false)
        }
    }

    // Existing installs have no cache-format row, so a missing value
    // must read as format 0, the stand-in for pre-marker caches.
    @Test func readCacheFormatVersionDefaultsToZeroWhenMissing() async throws {
        let (database, _) = try makeDatabase()
        #expect(try await database.readCacheFormatVersion() == 0)
        try await database.writeSyncedCommitHashOnly("c1")
        #expect(try await database.readCacheFormatVersion() == 0)
    }

    // replaceAll and applyMutation persist the observed format so a
    // later bump can force full rehydration.
    @Test func replaceAllAndApplyMutationPersistCacheFormatVersion() async throws {
        let (database, _) = try makeDatabase()
        let manifest = TestOriginalManifest(id: "img-1", guessedTakenAt: Date(), sha256: "sha-1")
        try await database.replaceAll(
            manifests: [manifest],
            commitHash: "commit-a",
            cacheFormatVersion: 0
        )
        #expect(try await database.readCacheFormatVersion() == 0)

        try await database.writeCacheFormatVersionOnly(99)
        #expect(try await database.readCacheFormatVersion() == 99)

        try await database.applyMutation(
            added: [],
            updated: [],
            removed: [],
            commitHash: "commit-b",
            cacheFormatVersion: 1
        )
        #expect(try await database.readCacheFormatVersion() == 1)
    }

    // Closing releases the GRDB queue so wipe paths can unlink the
    // sqlite file without leaving a live descriptor on a deleted vnode.
    @Test func closePreventsFurtherReads() async throws {
        let (database, _) = try makeDatabase()
        try await database.writeSyncedCommitHashOnly("c1")
        try await database.close()
        await #expect(throws: (any Error).self) {
            _ = try await database.readSyncedCommitHash()
        }
    }
}
