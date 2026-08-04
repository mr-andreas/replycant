import Foundation
import Testing
import LibGit2
@testable import iosapp

// Verifies reset behavior wipes local git state while preserving long-lived configuration and identity prerequisites.
@MainActor
@Suite(.serialized)
struct StateResetManagerTests {

    // Ensures the wipe routine deletes local repository data and clears cached runtime state without deleting server defaults.
    @Test func testWipeLocalStateKeepingKeysDeletesRepoAndClearsCaches() async throws {
        let originalGitURL = UserDefaults.standard.string(forKey: "gitServerURL")
        defer {
            if let originalGitURL {
                UserDefaults.standard.set(originalGitURL, forKey: "gitServerURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "gitServerURL")
            }
            RepositoryManager.shared.clearRepository()
            ManifestLoaderManager.shared.clearLoader()
        }

        UserDefaults.standard.set("https://example.com/repo.git", forKey: "gitServerURL")

        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("replycant-state-reset-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        let repository = try Repository.create(at: repoPath)
        RepositoryManager.shared.cacheRepositoryForTesting(repository)
        _ = try ManifestLoaderManager.shared.getDatabase()

        #expect(RepositoryManager.shared.hasCachedRepositoryForTesting)
        #expect(ManifestLoaderManager.shared.hasCachedLoaderForTesting)
        #expect(FileManager.default.fileExists(atPath: repoPath))

        try await StateResetManager.shared.wipeLocalStateKeepingKeys(repositoryPath: repoPath)

        #expect(!FileManager.default.fileExists(atPath: repoPath))
        #expect(UserDefaults.standard.string(forKey: "gitServerURL") != nil)
        RepositoryManager.shared.clearRepository()
        ManifestLoaderManager.shared.clearLoader()
        #expect(!RepositoryManager.shared.hasCachedRepositoryForTesting)
        #expect(!ManifestLoaderManager.shared.hasCachedLoaderForTesting)
    }
}
