import Foundation
import LibGit2
import Combine
import OSLog

// Emits GitDB signposts so Instruments can attribute combined git+SQL mutation latency.
private enum GitDBSignposts {
    private static let logger = Logger(subsystem: "com.replycant.gitdb", category: "PointsOfInterest")
    static let signposter = OSSignposter(logger: logger)

    // Starts one GitDB signposted interval.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    // Ends one GitDB signposted interval without metadata.
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}

// Enforces that HEAD mutations route through GitDB so SQL cache
// consistency is not left to each caller. Recovery may skip the
// first sync only before the cache has ever been hydrated.
public final class GitDatabase: Sendable {
    // Names bootstrap-commit failures so recovery cannot skip sync
    // after the cache has already been hydrated.
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case cacheAlreadyHydrated

        // Explains why a pre-hydration commit was refused so callers
        // fall back to the syncing commit path.
        public var errorDescription: String? {
            switch self {
            case .cacheAlreadyHydrated:
                return "commitFilesWithoutSync is only valid before the cache has been hydrated."
            }
        }
    }

    private let repository: Repository
    private let database: ManifestDatabase
    private let syncEngine: ManifestSyncEngine

    // Exposes manifest DB change notifications for timeline and other subscribers.
    public var changes: PassthroughSubject<ManifestDatabaseChange, Never> {
        database.changes
    }

    // Binds one repository to one manifest database for deterministic git->SQL consistency.
    public init(repository: Repository, database: ManifestDatabase, registry: ManifestRegistry) {
        self.repository = repository
        self.database = database
        self.syncEngine = ManifestSyncEngine(repository: repository, database: database, registry: registry)
    }

    // Commits manifest/LFS items and immediately mirrors the resulting change into SQL state.
    public func commitManifests(
        message: String,
        items: [GitCommitItem],
        deviceSpace: String,
        lfsClient: GitLFS
    ) async throws {
        let signpost = GitDBSignposts.begin("GitDBCommitManifests")
        var succeeded = false
        defer {
            if succeeded {
                GitDBSignposts.signposter.endInterval(
                    "GitDBCommitManifests",
                    signpost,
                    "items=\(items.count, privacy: .public)"
                )
            } else {
                GitDBSignposts.end("GitDBCommitManifests", signpost)
            }
        }
        try await repository.withMutationLock {
            let commitService = DefaultGitCommitService(repository: repository, deviceSpace: deviceSpace, lfsClient: lfsClient)
            try await commitService.createCommit(message: message, items: items)
            try await syncEngine.syncAfterCommit(items: items)
        }
        succeeded = true
    }

    // Commits raw file updates/deletions and then converges SQL state to current HEAD.
    public func commitFiles(
        message: String,
        files: [(path: String, content: String)],
        deletions: [String] = []
    ) async throws {
        let signpost = GitDBSignposts.begin("GitDBCommitFiles")
        var succeeded = false
        defer {
            if succeeded {
                GitDBSignposts.signposter.endInterval(
                    "GitDBCommitFiles",
                    signpost,
                    "files=\(files.count, privacy: .public) deletions=\(deletions.count, privacy: .public)"
                )
            } else {
                GitDBSignposts.end("GitDBCommitFiles", signpost)
            }
        }
        try await repository.withMutationLock {
            try repository.createCommit(message: message, files: files, deletions: deletions)
            try await syncEngine.syncToHead(progressHandler: nil)
        }
        succeeded = true
    }

    // Commits raw files without hydrating SQL so recovery can enroll a
    // device key and push before the first (and only) index build.
    public func commitFilesWithoutSync(
        message: String,
        files: [(path: String, content: String)],
        deletions: [String] = []
    ) async throws {
        let signpost = GitDBSignposts.begin("GitDBCommitFilesWithoutSync")
        var succeeded = false
        defer {
            if succeeded {
                GitDBSignposts.signposter.endInterval(
                    "GitDBCommitFilesWithoutSync",
                    signpost,
                    "files=\(files.count, privacy: .public) deletions=\(deletions.count, privacy: .public)"
                )
            } else {
                GitDBSignposts.end("GitDBCommitFilesWithoutSync", signpost)
            }
        }
        try await repository.withMutationLock {
            if try await database.readSyncedCommitHash() != nil {
                throw Error.cacheAlreadyHydrated
            }
            try repository.createCommit(message: message, files: files, deletions: deletions)
        }
        succeeded = true
    }

    // Pulls remote history and synchronizes SQL state so readers immediately observe new HEAD.
    public func pull(
        remoteName: String = "origin",
        branchName: String,
        progressHandler: SyncProgressHandler? = nil
    ) async throws {
        let signpost = GitDBSignposts.begin("GitDBPull")
        var succeeded = false
        defer {
            if succeeded {
                GitDBSignposts.signposter.endInterval(
                    "GitDBPull",
                    signpost,
                    "branch=\(branchName, privacy: .public)"
                )
            } else {
                GitDBSignposts.end("GitDBPull", signpost)
            }
        }
        try await repository.withMutationLock {
            try repository.pullRebase(remoteName: remoteName, branchName: branchName, progressCallback: nil)
            try await syncEngine.syncToHead(progressHandler: progressHandler)
        }
        succeeded = true
    }

    // Synchronizes SQL state to current HEAD without mutating git history.
    public func syncToHead(progressHandler: SyncProgressHandler? = nil) async throws {
        try await syncEngine.syncToHead(progressHandler: progressHandler)
    }

    // Executes a raw SQL query and decodes each row's payload into the requested manifest type.
    public func query<T: Manifest>(
        _ type: T.Type,
        sql: String,
        arguments: QueryArguments = QueryArguments()
    ) async throws -> [T] {
        try await database.query(type, sql: sql, arguments: arguments)
    }

    // Executes a raw SQL count query.
    public func queryCount(
        sql: String,
        arguments: QueryArguments = QueryArguments()
    ) async throws -> Int {
        try await database.queryCount(sql: sql, arguments: arguments)
    }

    // Resolves the backing table name for a registered manifest type.
    public func tableName<T: Manifest>(for type: T.Type) async throws -> String {
        try await database.tableName(for: type)
    }

}
