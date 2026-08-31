import Foundation
import Testing
import LibGit2
@testable import GitDB

// Pins GitDB as the single remote-operation owner so push/pull
// skip cleanly when another mutation is already in flight.
struct GitDBRemoteTests {
    // Creates isolated repository/database fixtures for remote coverage.
    private func makeFixture() throws -> (Repository, ManifestDatabase, ManifestRegistry, repoPath: String, dbURL: URL) {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-remote-repo-\(UUID().uuidString)")
            .path
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        try repository.createCommit(
            message: "seed",
            files: [("gitdb/version", "1\n")]
        )
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-remote-db-\(UUID().uuidString).sqlite")
        let registry = makeTestRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        return (repository, database, registry, repoPath, dbURL)
    }

    // tryPush must return false immediately when the mutation lock is
    // already held so periodic ticks never wait on a user-facing write.
    @Test func tryPushReturnsFalseWhenMutationLockIsHeld() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        try await repository.withMutationLock {
            let pushed = try await gitDB.tryPush()
            #expect(pushed == false)
        }
    }

    // tryPull must return false immediately when the mutation lock is
    // already held so background rebase cannot overlap a commit.
    @Test func tryPullReturnsFalseWhenMutationLockIsHeld() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        try await repository.withMutationLock {
            let pulled = try await gitDB.tryPull()
            #expect(pulled == false)
        }
    }

    // push(nil) must resolve the current branch so callers never pass
    // `currentBranch() ?? "main"` themselves.
    @Test func pushResolvesDefaultBranchWhenBranchNameIsNil() async throws {
        let (repository, database, registry, repoPath, dbURL) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
            try? FileManager.default.removeItem(at: dbURL)
        }

        #expect(repository.currentBranch() == "main")
        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        #expect(gitDB.resolvedBranch(nil) == "main")
        #expect(gitDB.resolvedBranch("feature") == "feature")
    }
}
