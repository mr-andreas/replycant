import Foundation
import Combine
import Testing
@testable import GitDB
@testable import iosapp

// Verifies app schema registration works with generic GitDB storage/query APIs.
@MainActor
struct ManifestDatabaseTests {
    // Creates a test registry matching the app's registered query columns.
    private func makeRegistry() -> ManifestRegistry {
        let registry = ManifestRegistry()
        registry.register(OriginalManifest.self) { reg in
            reg.column("guessedTakenAt", type: .real, nullable: true)
            reg.column("sha256", type: .text)
            reg.index(on: ["guessedTakenAt", "id"], where: "guessedTakenAt IS NOT NULL")
            reg.index(on: ["sha256"])
            reg.extractColumns { manifest in
                [
                    "guessedTakenAt": manifest.spec.guessedTakenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "sha256": .string(manifest.spec.sha256),
                ]
            }
        }
        registry.register(ThumbnailSetManifest.self) { reg in
            reg.column("originalRef", type: .text)
            reg.index(on: ["originalRef"])
            reg.extractColumns { manifest in
                [
                    "originalRef": .string(manifest.spec.originalRef),
                ]
            }
        }
        return registry
    }

    // Creates a database rooted in a temporary file so each test gets isolated schema state.
    private func makeDatabase() throws -> (ManifestDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-db-\(UUID().uuidString).sqlite")
        return (try ManifestDatabase(databaseURL: url, registry: makeRegistry()), url)
    }

    // Produces a minimal original manifest fixture with configurable guessedTakenAt and sha256 values.
    private func makeOriginal(id: String, guessedTakenAt: Date?, sha256: String, deviceSpace: String = "device-a") -> OriginalManifest {
        OriginalManifest(
            id: id,
            localID: "local-\(id)",
            sha256: sha256,
            path: "/tmp/\(id).jpg",
            filesize: 2048,
            name: id,
            deviceSpace: deviceSpace,
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
            guessedTakenAt: guessedTakenAt
        )
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

    // Ensures timeline count and ordering can be expressed through generic SQL queries.
    @Test func queryCountAndOrdering() async throws {
        let (database, _) = try makeDatabase()
        let originals: [any Manifest] = [
            makeOriginal(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "s1"),
            makeOriginal(id: "a", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "s2"),
            makeOriginal(id: "c", guessedTakenAt: nil, sha256: "s3"),
            makeOriginal(id: "d", guessedTakenAt: Date(timeIntervalSince1970: 10), sha256: "s4"),
        ]
        try await database.applyMutation(added: originals, updated: [], removed: [], commitHash: "c1")
        let table = try await database.tableName(for: OriginalManifest.self)
        #expect(try await database.queryCount(
            sql: "SELECT COUNT(*) FROM \(table) WHERE guessedTakenAt IS NOT NULL AND guessedTakenAt > ?",
            arguments: [0.0]
        ) == 3)
        let page = try await database.query(OriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE guessedTakenAt IS NOT NULL
            ORDER BY guessedTakenAt ASC, id ASC
            LIMIT ? OFFSET ?
        """, arguments: [2, 0])
        #expect(page.map(\.id) == ["d", "a"])
    }

    // Verifies generic incremental payloads are emitted for subscribers.
    @Test func applyMutationPublishesIncremental() async throws {
        let (database, _) = try makeDatabase()
        let old = makeOriginal(id: "old", guessedTakenAt: Date(), sha256: "sha-old")
        let new = makeOriginal(id: "new", guessedTakenAt: Date(), sha256: "sha-new")
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
            #expect(Bool(false))
        case .incremental(let mutation):
            #expect(mutation.added.first?.id == "new")
            #expect(mutation.updated.isEmpty)
            #expect(mutation.removed.first?.id == "old")
            #expect((mutation.removed.first as? OriginalManifest)?.spec.sha256 == "sha-old")
        }
    }

    // Verifies overwrites are emitted as updated rather than added.
    @Test func applyMutationPublishesUpdated() async throws {
        let (database, _) = try makeDatabase()
        let old = makeOriginal(id: "same-id", guessedTakenAt: Date(), sha256: "sha-old")
        let replacement = makeOriginal(id: "same-id", guessedTakenAt: Date(), sha256: "sha-new")
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
            #expect(Bool(false))
        case .incremental(let mutation):
            #expect(mutation.added.isEmpty)
            #expect(mutation.updated.count == 1)
            #expect((mutation.updated.first as? OriginalManifest)?.spec.sha256 == "sha-new")
            #expect(mutation.removed.isEmpty)
        }
    }
}
