import Foundation
import LibGit2
import GitDB

// Provides a shared GitDB facade so HEAD mutations always run with SQL synchronization.
@MainActor
final class GitDBManager {
    static let shared = GitDBManager()

    private var gitDB: GitDatabase?
    private let notificationCenter: NotificationCenter
    private var databaseInvalidationObserver: NSObjectProtocol?

    // The notification center is injectable so a test can prove the
    // cache drops on a private center. Observing the default center
    // from a test would also clear the process-wide shared instance.
    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        databaseInvalidationObserver = notificationCenter.addObserver(
            forName: ManifestLoaderManager.databaseDidInvalidateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearGitDB()
            }
        }
    }

    // Drops the invalidation observer so test-created managers do not
    // keep a center callback after they leave scope.
    deinit {
        if let databaseInvalidationObserver {
            notificationCenter.removeObserver(databaseInvalidationObserver)
        }
    }

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

    // Exposes GitDB cache state so invalidation tests can assert a
    // synchronous drop without awaiting the next getGitDB() call.
    var hasCachedGitDBForTesting: Bool {
        gitDB != nil
    }
}
