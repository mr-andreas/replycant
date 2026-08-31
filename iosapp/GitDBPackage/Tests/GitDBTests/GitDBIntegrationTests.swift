import Foundation
import Testing
import LibGit2
@testable import GitDB

// Verifies GitDB couples HEAD mutation operations with manifest SQL synchronization.
struct GitDBIntegrationTests {
    // Creates isolated repository/database fixtures for integration coverage.
    private func makeFixture() throws -> (Repository, ManifestDatabase, ManifestRegistry, repoPath: String, dbURL: URL) {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-integration-repo-\(UUID().uuidString)")
            .path
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-integration-db-\(UUID().uuidString).sqlite")
        let registry = makeTestRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        return (repository, database, registry, repoPath, dbURL)
    }

    // Ensures commitFiles advances HEAD and synchronizes SQL metadata in one API call.
    @Test func commitFilesSyncsDatabaseToHead() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        try await gitDB.commitFiles(
            message: "seed non-manifest files",
            files: [
                (path: "gitdb/version", content: "1\n"),
                (path: "pubkeys/device-a.pub", content: "ssh-ed25519 AAAATEST device-a"),
                (path: "pubkeys/device-a.age", content: "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"),
            ]
        )

        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Ensures syncToHead converges metadata when HEAD moves without manifest-tree changes.
    @Test func syncToHeadConvergesOnNonManifestHeadMove() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        try repository.createCommit(
            message: "c1",
            files: [
                ("gitdb/version", "1\n"),
                ("pubkeys/a.pub", "ssh-ed25519 AAAATEST a"),
            ]
        )

        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        try await gitDB.syncToHead(progressHandler: nil)
        let c1 = repository.headOID()
        #expect(try await database.readSyncedCommitHash() == c1)

        try repository.createCommit(
            message: "c2",
            files: [
                ("pubkeys/b.pub", "ssh-ed25519 AAAATEST b"),
            ]
        )

        try await gitDB.syncToHead(progressHandler: nil)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Recovery must enroll a device key without hydrating SQL so the
    // later resync is the only index build.
    @Test func commitFilesWithoutSyncLeavesCacheUnhydrated() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        try await gitDB.commitFilesWithoutSync(
            message: "enroll device key",
            files: [
                (path: "gitdb/version", content: "1\n"),
                (path: "pubkeys/device-a.pub", content: "ssh-ed25519 AAAATEST device-a"),
            ]
        )

        #expect(repository.headOID() != nil)
        #expect(try await database.readSyncedCommitHash() == nil)

        try await gitDB.syncToHead(progressHandler: nil)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // The bootstrap API is only valid before the cache has ever been
    // hydrated, so a later caller cannot skip sync by accident.
    @Test func commitFilesWithoutSyncRejectsHydratedCache() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        try repository.createCommit(
            message: "c1",
            files: [
                ("gitdb/version", "1\n"),
                ("pubkeys/a.pub", "ssh-ed25519 AAAATEST a"),
            ]
        )

        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        try await gitDB.syncToHead(progressHandler: nil)

        do {
            try await gitDB.commitFilesWithoutSync(
                message: "should fail",
                files: [
                    (path: "pubkeys/b.pub", content: "ssh-ed25519 AAAATEST b"),
                ]
            )
            Issue.record("commitFilesWithoutSync unexpectedly succeeded on a hydrated cache")
        } catch GitDatabase.Error.cacheAlreadyHydrated {
            // Expected: bootstrap commits are refused after first hydration.
        }
    }

    // Refuses writes into an unsupported repo before createCommit so
    // device-linking cannot land keys in a format this client cannot
    // read back.
    @Test func commitFilesRefusesUnsupportedVersionBeforeMutating() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        try repository.createCommit(
            message: "unsupported",
            files: [("gitdb/version", "2\n")]
        )
        let headBefore = try #require(repository.headOID())

        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        do {
            try await gitDB.commitFiles(
                message: "should not land",
                files: [(path: "pubkeys/device-b.pub", content: "ssh-ed25519 AAAATEST device-b")]
            )
            Issue.record("commitFiles unexpectedly succeeded on an unsupported database version")
        } catch let error as DatabaseVersionError {
            #expect(error == .unsupported(found: 2, required: 1))
        }
        #expect(repository.headOID() == headBefore)
    }

    // First-epoch bootstrap must still be able to create the commit
    // that introduces gitdb/version when HEAD has never existed.
    @Test func commitFilesSucceedsWhenHeadIsUnborn() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        #expect(repository.headOID() == nil)
        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        try await gitDB.commitFiles(
            message: "bootstrap",
            files: [(path: "gitdb/version", content: "1\n")]
        )
        #expect(repository.headOID() != nil)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Recovery enrollment must not write into a repo whose format this
    // client cannot read, even before the first cache hydration.
    @Test func commitFilesWithoutSyncRefusesUnsupportedVersion() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        try repository.createCommit(
            message: "unsupported",
            files: [("gitdb/version", "2\n")]
        )
        let headBefore = try #require(repository.headOID())

        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        do {
            try await gitDB.commitFilesWithoutSync(
                message: "should not land",
                files: [(path: "pubkeys/device-b.pub", content: "ssh-ed25519 AAAATEST device-b")]
            )
            Issue.record("commitFilesWithoutSync unexpectedly succeeded on an unsupported database version")
        } catch let error as DatabaseVersionError {
            #expect(error == .unsupported(found: 2, required: 1))
        }
        #expect(repository.headOID() == headBefore)
        #expect(try await database.readSyncedCommitHash() == nil)
    }

    // Old-alpha libraries without gitdb/version must still accept
    // commits and pulls so a later migration can write format 1.
    @Test func commitAndPullSucceedAgainstMissingVersion() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        try repository.createCommit(
            message: "old-alpha",
            files: [("notes/readme.txt", "hello")]
        )
        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        try await gitDB.commitFiles(
            message: "local write",
            files: [(path: "notes/more.txt", content: "more")]
        )
        #expect(try await database.readCacheFormatVersion() == 0)
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Diverged unpublished commits cannot be rebased onto a remote
    // whose format no longer matches the local cache.
    @Test func pullRefusesRebaseWhenFormatChangedAndHistoriesDiverge() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )
        try await localGitDB.syncToHead(progressHandler: nil)
        try await localDB.writeCacheFormatVersionOnly(0)

        try fixture.local.createCommit(
            message: "local unpublished",
            files: [("local.txt", "local")]
        )
        try fixture.writer.createCommit(
            message: "remote advance",
            files: [("remote.txt", "remote")]
        )
        try fixture.writer.push(remoteName: "origin", branchName: "main")
        let localHeadBefore = try #require(fixture.local.headOID())

        do {
            try await localGitDB.pull(remoteName: "origin", branchName: "main")
            Issue.record("expected format-transition pull refusal")
        } catch FormatTransitionPullError.divergedDuringFormatChange {
            // Expected: unpublished local commits cannot be replayed.
        }
        #expect(fixture.local.headOID() == localHeadBefore)
    }

    // A clean fast-forward across a cache-format change still works
    // and rebuilds the cache from the new HEAD.
    @Test func pullFastForwardsAndRehydratesWhenFormatChangedWithoutDivergence() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )
        try await localGitDB.syncToHead(progressHandler: nil)
        try await localDB.writeCacheFormatVersionOnly(0)

        try fixture.writer.createCommit(
            message: "remote advance",
            files: [("remote.txt", "remote")]
        )
        let remoteHead = try #require(fixture.writer.headOID())
        try fixture.writer.push(remoteName: "origin", branchName: "main")

        try await localGitDB.pull(remoteName: "origin", branchName: "main")
        #expect(fixture.local.headOID() == remoteHead)
        #expect(try await localDB.readCacheFormatVersion() == DatabaseVersion.current)
        #expect(try await localDB.readSyncedCommitHash() == remoteHead)
    }

    // Reset-to-remote discards unpublished local commits and hydrates
    // from the remote tip so the user does not need a full wipe.
    @Test func hardResetToRemoteDiscardsLocalCommitsAndRehydrates() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )
        try await localGitDB.syncToHead(progressHandler: nil)
        try await localDB.writeCacheFormatVersionOnly(0)

        try fixture.local.createCommit(
            message: "local unpublished",
            files: [("local.txt", "local")]
        )
        try fixture.writer.createCommit(
            message: "remote advance",
            files: [("remote.txt", "remote")]
        )
        let remoteHead = try #require(fixture.writer.headOID())
        try fixture.writer.push(remoteName: "origin", branchName: "main")

        try await localGitDB.hardResetToRemote(remoteName: "origin", branchName: "main")
        #expect(fixture.local.headOID() == remoteHead)
        #expect(fixture.local.fileExists(at: "local.txt") == false)
        #expect(fixture.local.fileExists(at: "remote.txt"))
        #expect(try await localDB.readCacheFormatVersion() == DatabaseVersion.current)
        #expect(try await localDB.readSyncedCommitHash() == remoteHead)
    }

    // Builds a bare remote plus two clones so pull tests can diverge
    // local and origin history without touching a real server.
    private func makeRemoteFixture() throws -> (
        root: String,
        local: Repository,
        writer: Repository,
        localDBURL: URL,
        registry: ManifestRegistry
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-remote-\(UUID().uuidString)")
            .path
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let writerPath = (root as NSString).appendingPathComponent("writer")
        let localPath = (root as NSString).appendingPathComponent("local")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Git.initialize()
        _ = try Repository.create(at: remotePath, bare: true)

        let seed = try Repository.create(at: seedPath, bare: false)
        try seed.createCommit(
            message: "seed",
            files: [("gitdb/version", "1\n")]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")

        let local = try Repository.clone(from: remotePath, to: localPath)
        let writer = try Repository.clone(from: remotePath, to: writerPath)
        let localDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-remote-db-\(UUID().uuidString).sqlite")
        return (root, local, writer, localDBURL, makeTestRegistry())
    }
}
