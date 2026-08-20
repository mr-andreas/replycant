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
}
