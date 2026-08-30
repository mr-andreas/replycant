import Foundation
import GitDB
import LibGit2
import Testing
@testable import iosapp

// Guards the recovery hydrate path against unlinking the shared sqlite
// file while GitDB still holds an open GRDB connection to it.
@MainActor
@Suite(.serialized, .sharedAppState)
struct RepositoryBootstrapResetTests {

    // Recovery opens GitDB for the key-rewrap commit and then rebuilds
    // the media index. Deleting the cache file at that point left the
    // cached connection pointing at an unlinked vnode, so the next
    // `PRAGMA query_only` failed with a disk I/O error.
    @Test func hydrateIndexResetKeepsLiveDatabaseConnection() async throws {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("replycant-bootstrap-reset-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        let repository = try Repository.create(at: repoPath, bare: false)
        RepositoryManager.shared.cacheRepositoryForTesting(repository)
        GitDBManager.shared.clearGitDB()
        ManifestLoaderManager.shared.clearLoader()
        defer {
            RepositoryManager.shared.clearRepository()
            GitDBManager.shared.clearGitDB()
            ManifestLoaderManager.shared.clearLoader()
        }

        let database = try ManifestLoaderManager.shared.getDatabase()
        _ = try GitDBManager.shared.getGitDB()
        let databaseIdentity = ObjectIdentifier(database)
        let databaseURL = ManifestDatabase.defaultDatabaseURL()
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))

        try await RepositoryBootstrap.hydrateIndex(resetDatabase: true)

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        let reusedDatabase = try ManifestLoaderManager.shared.getDatabase()
        #expect(ObjectIdentifier(reusedDatabase) == databaseIdentity)
    }
}
