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

    // A cache built by this version of the app must survive relaunch, so
    // reopening the same file with the same schema version keeps rows and
    // the commit they were hydrated from.
    @Test func reopeningWithSameSchemaVersionKeepsRowsAndSyncedCommit() async throws {
        let url = temporaryDatabaseURL()
        let registry = makeVersionedRegistry(schemaVersion: 1, includeLatitude: false)
        let database = try ManifestDatabase(databaseURL: url, registry: registry)
        let manifest = TestOriginalManifest(id: "img-1", guessedTakenAt: Date(), sha256: "sha-1")
        try await database.applyMutation(added: [manifest], updated: [], removed: [], commitHash: "commit-a")
        try await database.close()

        let reopened = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 1, includeLatitude: false))
        let table = try await reopened.tableName(for: TestOriginalManifest.self)
        #expect(try await reopened.queryCount(sql: "SELECT COUNT(*) FROM \(table)") == 1)
        #expect(try await reopened.readSyncedCommitHash() == "commit-a")
        #expect(try await reopened.isHydrated() == true)
        try await reopened.close()
    }

    // Shipping a newer schema must discard the old cache instead of
    // querying columns that were never created. The replacement version
    // has to stick, or the next launch would wipe the rebuilt cache too.
    @Test func reopeningWithHigherSchemaVersionErasesCacheAndStoresNewVersion() async throws {
        let url = temporaryDatabaseURL()
        let database = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 1, includeLatitude: false))
        let manifest = TestOriginalManifest(id: "img-1", guessedTakenAt: Date(), sha256: "sha-1")
        try await database.applyMutation(added: [manifest], updated: [], removed: [], commitHash: "commit-a")
        try await database.close()

        let upgraded = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 2, includeLatitude: false))
        let table = try await upgraded.tableName(for: TestOriginalManifest.self)
        #expect(try await upgraded.queryCount(sql: "SELECT COUNT(*) FROM \(table)") == 0)
        #expect(try await upgraded.readSyncedCommitHash() == nil)
        #expect(try await upgraded.isHydrated() == false)

        let replacement = TestOriginalManifest(id: "img-2", guessedTakenAt: Date(), sha256: "sha-2")
        try await upgraded.applyMutation(added: [replacement], updated: [], removed: [], commitHash: "commit-b")
        try await upgraded.close()

        let kept = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 2, includeLatitude: false))
        #expect(try await kept.queryCount(sql: "SELECT COUNT(*) FROM \(table)") == 1)
        #expect(try await kept.readSyncedCommitHash() == "commit-b")
        try await kept.close()
    }

    // An older build opening a newer cache must not read a schema it does
    // not understand, so a downgrade wipes and records its own version.
    @Test func reopeningWithLowerSchemaVersionErasesCacheAndStoresNewVersion() async throws {
        let url = temporaryDatabaseURL()
        let database = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 3, includeLatitude: false))
        let manifest = TestOriginalManifest(id: "img-1", guessedTakenAt: Date(), sha256: "sha-1")
        try await database.applyMutation(added: [manifest], updated: [], removed: [], commitHash: "commit-a")
        try await database.close()

        let downgraded = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 1, includeLatitude: false))
        let table = try await downgraded.tableName(for: TestOriginalManifest.self)
        #expect(try await downgraded.queryCount(sql: "SELECT COUNT(*) FROM \(table)") == 0)
        #expect(try await downgraded.isHydrated() == false)
        try await downgraded.applyMutation(added: [manifest], updated: [], removed: [], commitHash: "commit-b")
        try await downgraded.close()

        let kept = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 1, includeLatitude: false))
        #expect(try await kept.queryCount(sql: "SELECT COUNT(*) FROM \(table)") == 1)
        #expect(try await kept.readSyncedCommitHash() == "commit-b")
        try await kept.close()
    }

    // Adding a column is why the version exists: a cache created before
    // the column must be queryable on it after the version bump, which
    // only works once the old table has been thrown away and recreated.
    @Test func reopeningWithNewColumnAfterVersionBumpMakesColumnQueryable() async throws {
        let url = temporaryDatabaseURL()
        let database = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 1, includeLatitude: false))
        let manifest = TestOriginalManifest(id: "img-1", guessedTakenAt: Date(), sha256: "sha-1")
        try await database.replaceAll(manifests: [manifest], commitHash: "commit-a")
        try await database.close()

        let upgraded = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 2, includeLatitude: true))
        let table = try await upgraded.tableName(for: TestOriginalManifest.self)
        #expect(try await upgraded.queryCount(sql: "SELECT COUNT(*) FROM \(table)") == 0)
        #expect(try await upgraded.queryCount(sql: "SELECT COUNT(latitude) FROM \(table)") == 0)
        #expect(try await upgraded.isHydrated() == false)
        try await upgraded.close()
    }

    // Launch rebuilds the index only when git still has the library but
    // the cache has not been hydrated, including right after a version wipe.
    @Test func isHydratedIsFalseUntilACommitIsSyncedAndFalseAfterErase() async throws {
        let url = temporaryDatabaseURL()
        let database = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 1, includeLatitude: false))
        #expect(try await database.isHydrated() == false)
        let manifest = TestOriginalManifest(id: "img-1", guessedTakenAt: Date(), sha256: "sha-1")
        try await database.replaceAll(manifests: [manifest], commitHash: "commit-a")
        #expect(try await database.isHydrated() == true)
        try await database.close()

        let erased = try ManifestDatabase(databaseURL: url, registry: makeVersionedRegistry(schemaVersion: 2, includeLatitude: false))
        #expect(try await erased.isHydrated() == false)
        try await erased.close()
    }

    // Keeps schema-version fixtures out of the shared test registry so
    // unrelated tests stay on the default version.
    private func makeVersionedRegistry(schemaVersion: Int, includeLatitude: Bool) -> ManifestRegistry {
        let registry = ManifestRegistry(schemaVersion: schemaVersion)
        registry.register(TestOriginalManifest.self) { reg in
            reg.column("guessedTakenAt", type: .real, nullable: true)
            reg.column("sha256", type: .text)
            if includeLatitude {
                reg.column("latitude", type: .real, nullable: true)
            }
            reg.extractColumns { manifest in
                [
                    "guessedTakenAt": manifest.spec.guessedTakenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "sha256": .string(manifest.spec.sha256),
                ]
            }
        }
        return registry
    }

    // Gives each schema-version case its own file so reopening cannot
    // observe another test's rows.
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-schema-\(UUID().uuidString).sqlite")
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
