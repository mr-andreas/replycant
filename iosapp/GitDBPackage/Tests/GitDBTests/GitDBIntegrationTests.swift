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

    // A key write is only done when the commit is also on the server.
    // The cache records that same HEAD, so readers never observe a
    // change that was not published.
    @Test func durableCommitPublishesFilesAndSyncsCache() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )

        try await localGitDB.durableCommit(message: "add device key") { _ in
            GitFileChange(files: [("pubkeys/new.pub", "ssh-ed25519 AAAATEST new")])
        }

        let published = try #require(fixture.local.headOID())
        let remote = try Repository(path: (fixture.root as NSString).appendingPathComponent("remote.git"))
        #expect(remote.headOID() == published)
        #expect(fixture.local.oid(forRef: "refs/remotes/origin/main") == published)
        #expect(fixture.local.fileExists(at: "pubkeys/new.pub"))
        #expect(try await localDB.readSyncedCommitHash() == published)
    }

    // The tailnet wait happens before any git work. A device that is
    // still joining must not commit a key it cannot push.
    @Test func durableCommitSkipsChangeWhenConnectionFails() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let calls = DurableCallFlag()
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry,
            ensureConnected: { throw DurableConnectError.unavailable }
        )
        let headBefore = fixture.local.headOID()

        await #expect(throws: DurableConnectError.unavailable) {
            try await localGitDB.durableCommit(message: "should not commit") { _ in
                calls.mark()
                return GitFileChange(files: [("pubkeys/new.pub", "ssh")])
            }
        }

        #expect(calls.wasCalled() == false)
        #expect(fixture.local.headOID() == headBefore)
        #expect(fixture.local.fileExists(at: "pubkeys/new.pub") == false)
    }

    // Unpublished local commits would make this push a non-fast-forward
    // later, or replay onto someone else's history. Refuse before writing.
    @Test func durableCommitRefusesWhenLocalIsAhead() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        try fixture.local.createCommit(
            message: "local unpublished",
            files: [("local.txt", "local")]
        )
        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let calls = DurableCallFlag()
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )
        let headBefore = fixture.local.headOID()

        await #expect(throws: GitDatabase.Error.headNotAtRemote) {
            try await localGitDB.durableCommit(message: "should not commit") { _ in
                calls.mark()
                return GitFileChange(files: [("pubkeys/new.pub", "ssh")])
            }
        }

        #expect(calls.wasCalled() == false)
        #expect(fixture.local.headOID() == headBefore)
        #expect(fixture.local.fileExists(at: "pubkeys/new.pub") == false)
    }

    // Another device can publish while this one still shows a matching
    // tracking ref. The fetch is what makes that visible before we write.
    @Test func durableCommitRefusesWhenRemoteIsAhead() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        try fixture.writer.createCommit(
            message: "remote advance",
            files: [("remote.txt", "remote")]
        )
        try fixture.writer.push(remoteName: "origin", branchName: "main")
        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let calls = DurableCallFlag()
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )
        let headBefore = fixture.local.headOID()

        await #expect(throws: GitDatabase.Error.headNotAtRemote) {
            try await localGitDB.durableCommit(message: "should not commit") { _ in
                calls.mark()
                return GitFileChange(files: [("pubkeys/new.pub", "ssh")])
            }
        }

        #expect(calls.wasCalled() == false)
        #expect(fixture.local.headOID() == headBefore)
        #expect(fixture.local.fileExists(at: "pubkeys/new.pub") == false)
        #expect(fixture.local.fileExists(at: "remote.txt") == false)
    }

    // The server can move between the check and the push. That push is
    // rejected, and the commit we just created has to disappear so the
    // next attempt does not rebase a key change onto unknown history.
    @Test func durableCommitRollsBackWhenPushIsRejected() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )
        let base = try #require(fixture.local.headOID())

        await #expect(throws: Error.self) {
            try await localGitDB.durableCommit(message: "add device key") { _ in
                try fixture.writer.createCommit(
                    message: "race",
                    files: [("race.txt", "remote")]
                )
                try fixture.writer.push(remoteName: "origin", branchName: "main")
                return GitFileChange(files: [("pubkeys/ours.pub", "ssh")])
            }
        }

        let remote = try Repository(path: (fixture.root as NSString).appendingPathComponent("remote.git"))
        #expect(fixture.local.headOID() == base)
        #expect(fixture.local.fileExists(at: "pubkeys/ours.pub") == false)
        #expect(remote.fileExists(at: "pubkeys/ours.pub") == false)
        #expect(remote.fileExists(at: "race.txt"))
        #expect(try await localDB.readSyncedCommitHash() == nil)
    }

    // Fetch, commit, and push are one critical section. A photo upload
    // that starts inside the change has to wait until the publish ends.
    @Test func durableCommitHoldsMutationLockDuringChange() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )

        try await localGitDB.durableCommit(message: "add device key") { repository in
            let contended = try await repository.tryWithMutationLock { true }
            #expect(contended == nil)
            return GitFileChange(files: [("pubkeys/new.pub", "ssh")])
        }

        #expect(fixture.local.fileExists(at: "pubkeys/new.pub"))
    }

    // The settings refresh fetches on the shared repository, so it has
    // to wait out a durable write instead of racing its remote-tracking
    // refs. The ref stays at the old tip until the holder lets go.
    @Test func fetchWaitsUntilMutationLockIsReleased() async throws {
        let fixture = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let localDB = try ManifestDatabase(databaseURL: fixture.localDBURL, registry: fixture.registry)
        let localGitDB = GitDatabase(
            repository: fixture.local,
            database: localDB,
            registry: fixture.registry
        )
        let trackingRef = "refs/remotes/origin/main"
        let oldTip = try #require(fixture.local.oid(forRef: trackingRef))
        let entered = MutationLockSignal()
        let release = MutationLockSignal()

        let holding = Task {
            try await fixture.local.withMutationLock {
                await entered.markAcquired()
                await release.waitUntilAcquired()
            }
        }
        await entered.waitUntilAcquired()

        try fixture.writer.createCommit(
            message: "remote advance",
            files: [("remote.txt", "remote")]
        )
        try fixture.writer.push(remoteName: "origin", branchName: "main")
        let writerHead = try #require(fixture.writer.headOID())

        let fetching = Task {
            try await localGitDB.fetch()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fixture.local.oid(forRef: trackingRef) == oldTip)

        await release.markAcquired()
        try await holding.value
        try await fetching.value
        #expect(fixture.local.oid(forRef: trackingRef) == writerHead)
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

// Names a connection failure so the durable-write test can prove the
// change closure never ran.
private enum DurableConnectError: Error, Equatable {
    case unavailable
}

// Records whether a durable change ran. The closure is sendable, so a
// plain Bool captured from the test would not compile.
private final class DurableCallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func mark() {
        lock.lock()
        called = true
        lock.unlock()
    }

    func wasCalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }
}

// Lets a test hold the repository lock until it has observed that a
// fetch is still waiting, then release it.
private actor MutationLockSignal {
    private var isAcquired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markAcquired() {
        isAcquired = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilAcquired() async {
        if isAcquired {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
