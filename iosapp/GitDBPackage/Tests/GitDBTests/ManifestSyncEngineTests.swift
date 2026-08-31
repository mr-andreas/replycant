import Foundation
import Combine
import Testing
import LibGit2
@testable import GitDB

// Verifies commit-diff synchronization keeps the manifest database aligned with git HEAD.
@MainActor
struct ManifestSyncEngineTests {
    // Shards fixture names so manifest sync tests match production repository layout.
    private func shardName(_ name: String) -> String {
        if name.count < 5 {
            return name
        }
        let first = String(name.prefix(2))
        let second = String(name.dropFirst(2).prefix(2))
        let rest = String(name.dropFirst(4))
        return "\(first)/\(second)/\(rest)"
    }

    // Waits for the next database change while executing one sync operation.
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

    // Builds a temporary repository and database pair for sync engine tests.
    private func makeFixture() throws -> (Repository, ManifestDatabase, ManifestRegistry, repoPath: String, dbURL: URL) {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-sync-repo-\(UUID().uuidString)")
            .path
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-sync-db-\(UUID().uuidString).sqlite")
        let registry = makeTestRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        return (repository, database, registry, repoPath, dbURL)
    }

    // Builds a sync engine with an injected test KEK so fixtures decrypt without Keychain.
    private func makeEngine(
        repository: Repository,
        database: ManifestDatabase,
        registry: ManifestRegistry
    ) -> ManifestSyncEngine {
        ManifestSyncEngine(
            repository: repository,
            database: database,
            registry: registry,
            loadKEKForEpoch: { _ in testManifestKEK }
        )
    }

    // Encrypts one original YAML fixture for commit into git objects.
    private func encryptedOriginal(id: String, guessedTakenAt: String?) throws -> String {
        try encryptTestManifestYAML(testOriginalManifestYAML(id: id, guessedTakenAt: guessedTakenAt))
    }

    // Generates many encrypted original manifest files for parallel hydration coverage.
    private func originalManifestFiles(prefix: String, count: Int) throws -> [(String, String)] {
        try (0..<count).map { index in
            let id = "\(prefix)-\(index)"
            let day = String(format: "%02d", (index % 28) + 1)
            let path = "manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName(id)).yaml"
            let encrypted = try encryptedOriginal(id: id, guessedTakenAt: "2024-01-\(day)T10:00:00Z")
            return (path, encrypted)
        }
    }

    // Commits encrypted manifests plus epoch placeholders required by preloadAllKEKs.
    private func commitEncrypted(
        repository: Repository,
        message: String,
        manifestFiles: [(String, String)]
    ) throws {
        try repository.createCommit(message: message, files: testEpochPlaceholderFiles + manifestFiles)
    }

    // Ensures first sync fully hydrates database and emits progress updates during hydration.
    @Test func syncToHeadPerformsFullHydrationWithProgress() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        try commitEncrypted(
            repository: repository,
            message: "seed",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml", try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z")),
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("b")).yaml", try encryptedOriginal(id: "b", guessedTakenAt: nil)),
            ]
        )

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        var progressEvents: [(String, Int, Int)] = []
        try await engine.syncToHead { phase, loaded, total in
            progressEvents.append((phase, loaded, total))
        }

        let table = try await database.tableName(for: TestOriginalManifest.self)
        let timeline = try await database.query(TestOriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE guessedTakenAt IS NOT NULL
            ORDER BY guessedTakenAt ASC, id ASC
        """)
        #expect(timeline.map(\.id) == ["a"])
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
        #expect(progressEvents.contains { $0.0 == "Reading manifests" })
        #expect(progressEvents.contains { event in event.0 == "Updating database" && event.1 == 1 && event.2 == 1 })
    }

    // Ensures incremental sync applies changed files between two commits without full replacement.
    @Test func syncToHeadAppliesIncrementalChanges() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        try commitEncrypted(
            repository: repository,
            message: "c1",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml", try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z")),
            ]
        )

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)

        try commitEncrypted(
            repository: repository,
            message: "c2",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml", try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-02T10:00:00Z")),
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("c")).yaml", try encryptedOriginal(id: "c", guessedTakenAt: "2024-01-03T10:00:00Z")),
            ]
        )

        try await engine.syncToHead(progressHandler: nil)
        let table = try await database.tableName(for: TestOriginalManifest.self)
        let all = try await database.query(TestOriginalManifest.self, sql: "SELECT data FROM \(table)")
        #expect(Set(all.map(\.id)) == Set(["a", "c"]))
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Ensures a new commit with an identical manifest tree only advances the sync checkpoint.
    @Test func syncToHeadSkipsHydrationWhenManifestTreeIsUnchanged() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        let manifestPath = "manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml"
        let manifestYAML = try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z")

        try commitEncrypted(
            repository: repository,
            message: "c1",
            manifestFiles: [(manifestPath, manifestYAML)]
        )

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)

        try commitEncrypted(
            repository: repository,
            message: "c2-same-tree",
            manifestFiles: [(manifestPath, manifestYAML)]
        )

        var progressEvents: [(String, Int, Int)] = []
        try await engine.syncToHead { phase, loaded, total in
            progressEvents.append((phase, loaded, total))
        }

        let table = try await database.tableName(for: TestOriginalManifest.self)
        let all = try await database.query(TestOriginalManifest.self, sql: "SELECT data FROM \(table)")
        #expect(all.count == 1)
        #expect(all.first?.id == "a")
        #expect(progressEvents.isEmpty)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Ensures non-manifest file commits do not trigger full hydration when manifest trees are unchanged.
    @Test func syncToHeadSkipsHydrationForNonManifestOnlyCommit() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        try commitEncrypted(
            repository: repository,
            message: "c1",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml", try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z"))
            ]
        )

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)

        try repository.createCommit(
            message: "c2-non-manifest",
            files: [("notes/readme.txt", "hello")]
        )

        var progressEvents: [(String, Int, Int)] = []
        try await engine.syncToHead { phase, loaded, total in
            progressEvents.append((phase, loaded, total))
        }

        let table = try await database.tableName(for: TestOriginalManifest.self)
        let all = try await database.query(TestOriginalManifest.self, sql: "SELECT data FROM \(table)")
        #expect(all.count == 1)
        #expect(all.first?.id == "a")
        #expect(progressEvents.isEmpty)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Ensures full hydration remains correct when many manifests are parsed in parallel.
    @Test func syncToHeadPerformsFullHydrationForLargeBatch() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        let files = try originalManifestFiles(prefix: "full", count: 24)
        try commitEncrypted(repository: repository, message: "seed-many", manifestFiles: files)

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)

        let table = try await database.tableName(for: TestOriginalManifest.self)
        let all = try await database.query(TestOriginalManifest.self, sql: "SELECT data FROM \(table)")
        #expect(all.count == 24)
        #expect(Set(all.map(\.id)).count == 24)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Ensures syncAfterCommit classifies same-id writes as updates using pre-commit DB state.
    @Test func syncAfterCommitPublishesUpdatedWhenManifestAlreadyExists() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        let path = "manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml"
        let seedYAML = try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z")
        try commitEncrypted(repository: repository, message: "c1", manifestFiles: [(path, seedYAML)])

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)

        let replacementYAML = try encryptTestManifestYAML("""
        apiVersion: \(TestOriginalManifest.apiVersion)
        kind: \(TestOriginalManifest.kind)
        metadata:
          name: a
          deviceSpace: test-device
        spec:
          id: a
          sha256: sha-new
          guessedTakenAt: 2024-01-02T10:00:00Z
        status: {}
        """)
        try commitEncrypted(repository: repository, message: "c2", manifestFiles: [(path, replacementYAML)])

        let replacement = TestOriginalManifest(
            id: "a",
            deviceSpace: "test-device",
            guessedTakenAt: Date(timeIntervalSince1970: 1_704_191_200),
            sha256: "sha-new"
        )
        let change = try await captureNextChange(from: database, perform: {
            try await engine.syncAfterCommit(items: [.manifest(replacement)])
        })

        switch change {
        case .fullReplace:
            #expect(false)
        case .incremental(let mutation):
            #expect(mutation.added.isEmpty)
            #expect(mutation.updated.count == 1)
            #expect((mutation.updated.first as? TestOriginalManifest)?.spec.sha256 == "sha-new")
            #expect(mutation.removed.isEmpty)
        }
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Stored format 0 plus a version-1 marker at HEAD must rebuild
    // from HEAD, which is the 0-to-1 migration path.
    @Test func syncToHeadFullyRehydratesWhenCacheFormatDiffers() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        try commitEncrypted(
            repository: repository,
            message: "c1",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml", try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z")),
            ]
        )

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)
        try await database.writeCacheFormatVersionOnly(0)

        try commitEncrypted(
            repository: repository,
            message: "c2",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml", try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-02T10:00:00Z")),
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("c")).yaml", try encryptedOriginal(id: "c", guessedTakenAt: "2024-01-03T10:00:00Z")),
            ]
        )

        let change = try await captureNextChange(from: database, perform: {
            try await engine.syncToHead(progressHandler: nil)
        })
        guard case .fullReplace = change else {
            Issue.record("expected full rehydration across a cache-format change")
            return
        }
        #expect(try await database.readCacheFormatVersion() == DatabaseVersion.current)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
        let table = try await database.tableName(for: TestOriginalManifest.self)
        let all = try await database.query(TestOriginalManifest.self, sql: "SELECT data FROM \(table)")
        #expect(Set(all.map(\.id)) == Set(["a", "c"]))
    }

    // Matching cache format and marker must keep using incremental
    // apply so an upgrade of this binary does not rebuild every cache.
    @Test func syncToHeadStaysIncrementalWhenCacheFormatMatches() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        try commitEncrypted(
            repository: repository,
            message: "c1",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml", try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z")),
            ]
        )

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)
        #expect(try await database.readCacheFormatVersion() == DatabaseVersion.current)

        try commitEncrypted(
            repository: repository,
            message: "c2",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("c")).yaml", try encryptedOriginal(id: "c", guessedTakenAt: "2024-01-03T10:00:00Z")),
            ]
        )

        let change = try await captureNextChange(from: database, perform: {
            try await engine.syncToHead(progressHandler: nil)
        })
        guard case .incremental = change else {
            Issue.record("expected incremental apply when cache format matches")
            return
        }
        #expect(try await database.readCacheFormatVersion() == DatabaseVersion.current)
    }

    // Local commits after a format change must not incrementally
    // mutate a cache that was built for the previous layout.
    @Test func syncAfterCommitFullyRehydratesWhenCacheFormatDiffers() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        try commitEncrypted(
            repository: repository,
            message: "c1",
            manifestFiles: [
                ("manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml", try encryptedOriginal(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z")),
            ]
        )

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)
        try await database.writeCacheFormatVersionOnly(0)

        let added = TestOriginalManifest(id: "b", guessedTakenAt: Date(timeIntervalSince1970: 20), sha256: "sha-b")
        let change = try await captureNextChange(from: database, perform: {
            try await engine.syncAfterCommit(items: [.manifest(added)])
        })
        guard case .fullReplace = change else {
            Issue.record("expected full rehydration from syncAfterCommit across a format change")
            return
        }
        #expect(try await database.readCacheFormatVersion() == DatabaseVersion.current)
    }

    // Leaves an empty repository usable so first-run bootstrap can write
    // gitdb/version in the initial commit without being rejected first.
    @Test func syncToHeadAllowsEmptyRepositoryWithoutVersionMarker() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }
        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)
        #expect(try await database.readSyncedCommitHash() == nil)
    }

    // Refuses a populated repository whose marker does not match this client
    // so an already-running app cannot keep writing after a format bump.
    @Test func syncToHeadRejectsUnsupportedDatabaseVersion() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }
        try repository.createCommit(
            message: "unsupported-version",
            files: [("gitdb/version", "2\n")]
        )
        let engine = makeEngine(repository: repository, database: database, registry: registry)
        do {
            try await engine.syncToHead(progressHandler: nil)
            Issue.record("expected unsupported database version rejection")
        } catch let error as DatabaseVersionError {
            #expect(error == .unsupported(found: 2, required: 1))
        }
    }

    // A marker-less old-alpha repository is version 0 and must hydrate
    // without churning on every later incremental sync.
    @Test func syncToHeadAcceptsMissingMarkerAsVersionZero() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }
        try repository.createCommit(
            message: "missing-version",
            files: [
                ("encryption/current", "1\n"),
                ("encryption/epochs/1.age", "placeholder\n"),
                ("notes/readme.txt", "hello"),
            ]
        )
        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)
        #expect(try await database.readCacheFormatVersion() == 0)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())

        try repository.createCommit(
            message: "notes-only",
            files: [("notes/readme2.txt", "again")]
        )
        try await engine.syncToHead(progressHandler: nil)
        #expect(try await database.readCacheFormatVersion() == 0)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Stored format 1 plus an absent marker is a downgrade, not an
    // old library, so a hostile strip cannot look like version 0.
    @Test func syncToHeadRefusesWhenMarkerRemovedAfterVersionedCache() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }
        try repository.createCommit(
            message: "old-alpha",
            files: [
                ("encryption/current", "1\n"),
                ("encryption/epochs/1.age", "placeholder\n"),
                ("notes/readme.txt", "hello"),
            ]
        )
        let engine = makeEngine(repository: repository, database: database, registry: registry)
        try await engine.syncToHead(progressHandler: nil)
        #expect(try await database.readCacheFormatVersion() == 0)
        try await database.writeCacheFormatVersionOnly(1)

        do {
            try await engine.syncToHead(progressHandler: nil)
            Issue.record("expected marker-removed refusal")
        } catch let error as DatabaseVersionError {
            #expect(error == .markerRemoved(previouslySynced: 1))
        }
    }

    // Ensures a hostile server cannot strip the envelope and have clients accept plaintext YAML.
    @Test func syncToHeadRejectsPlaintextManifest() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        try commitEncrypted(
            repository: repository,
            message: "plaintext-attack",
            manifestFiles: [
                (
                    "manifests/test-device/\(TestOriginalManifest.apiVersion)/\(TestOriginalManifest.kind)/\(shardName("a")).yaml",
                    testOriginalManifestYAML(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z")
                ),
            ]
        )

        let engine = makeEngine(repository: repository, database: database, registry: registry)
        do {
            try await engine.syncToHead(progressHandler: nil)
            Issue.record("expected plaintext manifest rejection")
        } catch let error as ManifestDecryptionError {
            #expect(error == .plaintextManifestRejected)
        }
    }
}
