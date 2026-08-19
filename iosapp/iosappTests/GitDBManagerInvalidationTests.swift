import Foundation
import LibGit2
import Testing
@testable import iosapp

// Confirms GitDBManager drops its cached facade as soon as the shared
// manifest database is invalidated, so the next getGitDB() cannot
// return a connection bound to a discarded sqlite file.
@MainActor
@Suite(.serialized)
struct GitDBManagerInvalidationTests {

    // The cache must clear on the posting thread. A deferred main-queue
    // hop would let hydrateIndex call getGitDB() in the same turn and
    // still receive the stale GitDatabase.
    @Test func invalidationClearsCachedGitDBSynchronously() throws {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("replycant-gitdb-invalidation-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        let repository = try Repository.create(at: repoPath, bare: false)
        RepositoryManager.shared.cacheRepositoryForTesting(repository)
        defer {
            RepositoryManager.shared.clearRepository()
            ManifestLoaderManager.shared.clearLoader()
        }

        let center = NotificationCenter()
        let manager = GitDBManager(notificationCenter: center)
        _ = try manager.getGitDB()
        #expect(manager.hasCachedGitDBForTesting)

        center.post(
            name: ManifestLoaderManager.databaseDidInvalidateNotification,
            object: nil
        )

        #expect(!manager.hasCachedGitDBForTesting)
    }
}
