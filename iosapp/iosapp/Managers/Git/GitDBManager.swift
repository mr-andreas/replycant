import Foundation
import LibGit2
import GitDB

// Provides a shared GitDB facade so HEAD mutations always run with SQL synchronization.
@MainActor
final class GitDBManager {
    static let shared = GitDBManager()

    private var gitDB: GitDatabase?

    private init() {}

    // Returns a shared GitDB instance bound to the current repository and manifest cache file.
    func getGitDB() throws -> GitDatabase {
        if let gitDB {
            return gitDB
        }
        let repository = try RepositoryManager.shared.getRepository()
        let database = try ManifestLoaderManager.shared.getDatabase()
        let registry = ManifestLoaderManager.shared.getRegistry()
        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        self.gitDB = gitDB
        return gitDB
    }

    // Clears the cached GitDB instance after destructive resets.
    func clearGitDB() {
        gitDB = nil
    }
}
