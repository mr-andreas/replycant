import Foundation
import LibGit2
import GitDB

// Unifies manifest reads, git writes, and git-to-database sync so callers do not manage consistency steps manually.
// Declares write APIs locally to preserve main-actor isolation instead of inheriting a nonisolated protocol.
@MainActor
protocol ManifestManager: ManifestLoaderProtocol {
    func syncToHead(progressHandler: SyncProgressHandler?) async throws
    func loadOriginalBySHA256(_ sha256: String) async throws -> OriginalManifest?
    func loadUploadedLocalIDs() async throws -> [String: String?]
    func createCommit(message: String, items: [GitCommitItem]) async throws
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSData(_ data: Data, for manifest: any Manifest, progressHandler: ((Int64, Int64) -> Void)?) async throws -> LFSPointer
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSFileEncrypting(
        at fileURL: URL,
        dek: Data,
        oid: String,
        size: Int64,
        for manifest: any Manifest,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSData(
        _ data: Data,
        apiVersion: String,
        kind: String,
        name: String,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer
    func cancelActiveLFSUpload()
}

// Coordinates database-backed reads with git-first writes followed by cache synchronization.
@MainActor
final class DefaultManifestManager: ManifestManager {
    private let repository: Repository
    private let database: ManifestDatabase
    private let syncEngine: ManifestSyncEngine
    private let commitService: GitCommitService

    // Shares one manifest cache database and sync engine for all manager consumers tied to one repository.
    init(repository: Repository, deviceSpace: String, lfsClient: GitLFS, database: ManifestDatabase, registry: ManifestRegistry) {
        self.repository = repository
        self.database = database
        self.syncEngine = ManifestSyncEngine(repository: repository, database: database, registry: registry)
        self.commitService = DefaultGitCommitService(repository: repository, deviceSpace: deviceSpace, lfsClient: lfsClient)
    }

    // Enables tests to inject commit behavior while preserving production sync and read logic.
    init(repository: Repository, database: ManifestDatabase, commitService: GitCommitService, registry: ManifestRegistry) {
        self.repository = repository
        self.database = database
        self.syncEngine = ManifestSyncEngine(repository: repository, database: database, registry: registry)
        self.commitService = commitService
    }

    // Loads one manifest by id/device-space from the registered kind table.
    func loadManifest<T: Manifest>(deviceSpace: String?, id: String) async throws -> T? {
        let table = try await database.tableName(for: T.self)
        if let deviceSpace {
            return try await database.query(T.self, sql: """
                SELECT data
                FROM \(table)
                WHERE id = ? AND deviceSpace = ?
                LIMIT 1
            """, arguments: [id, deviceSpace]).first
        }
        return try await database.query(T.self, sql: """
            SELECT data
            FROM \(table)
            WHERE id = ?
            LIMIT 1
        """, arguments: [id]).first
    }

    // Loads all manifests of one type with timeline filtering for Original manifests.
    func loadAllManifests<T: Manifest>(deviceSpace: String?) async throws -> [T] {
        let table = try await database.tableName(for: T.self)
        if let deviceSpace, T.kind == OriginalManifest.kind {
            return try await database.query(T.self, sql: """
                SELECT data
                FROM \(table)
                WHERE deviceSpace = ? AND takenAt IS NOT NULL
            """, arguments: [deviceSpace])
        }
        if let deviceSpace {
            return try await database.query(T.self, sql: """
                SELECT data
                FROM \(table)
                WHERE deviceSpace = ?
            """, arguments: [deviceSpace])
        }
        if T.kind == OriginalManifest.kind {
            return try await database.query(T.self, sql: """
                SELECT data
                FROM \(table)
                WHERE takenAt IS NOT NULL
            """)
        }
        return try await database.query(T.self, sql: """
            SELECT data
            FROM \(table)
        """)
    }

    // Counts timeline-eligible originals so sparse timeline rendering can compute total scrollable length.
    func countTimelineOriginals() async throws -> Int {
        let table = try await database.tableName(for: OriginalManifest.self)
        return try await database.queryCount(sql: """
            SELECT COUNT(*)
            FROM \(table)
            WHERE takenAt IS NOT NULL
        """)
    }

    // Loads timeline rows by offset so random-position jumps can bootstrap sparse timeline content.
    func loadTimelinePage(offset: Int, limit: Int) async throws -> [OriginalManifest] {
        guard limit > 0 else { return [] }
        let table = try await database.tableName(for: OriginalManifest.self)
        let safeOffset = max(0, offset)
        return try await database.query(OriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE takenAt IS NOT NULL
            ORDER BY takenAt ASC, id ASC
            LIMIT ? OFFSET ?
        """, arguments: [limit, safeOffset])
    }

    // Loads timeline rows older than a cursor so sequential scrolling can extend toward history.
    func loadTimelinePage(before: TimelineCursor, limit: Int) async throws -> [OriginalManifest] {
        guard limit > 0 else { return [] }
        let table = try await database.tableName(for: OriginalManifest.self)
        let timestamp = before.date.timeIntervalSince1970
        let rows = try await database.query(OriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE takenAt IS NOT NULL
            AND (takenAt < ? OR (takenAt = ? AND id < ?))
            ORDER BY takenAt DESC, id DESC
            LIMIT ?
        """, arguments: [timestamp, timestamp, before.id, limit])
        return Array(rows.reversed())
    }

    // Loads timeline rows newer than a cursor so sequential scrolling can extend toward the present.
    func loadTimelinePage(after: TimelineCursor, limit: Int) async throws -> [OriginalManifest] {
        guard limit > 0 else { return [] }
        let table = try await database.tableName(for: OriginalManifest.self)
        let timestamp = after.date.timeIntervalSince1970
        return try await database.query(OriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE takenAt IS NOT NULL
            AND (takenAt > ? OR (takenAt = ? AND id > ?))
            ORDER BY takenAt ASC, id ASC
            LIMIT ?
        """, arguments: [timestamp, timestamp, after.id, limit])
    }

    // Aggregates month buckets directly in SQL so timeline jump UI can render only months that contain media.
    func loadTimelineMonthCounts() async throws -> [TimelineMonthCount] {
        let table = try await database.tableName(for: OriginalManifest.self)
        let rows = try await database.queryIntRows(sql: """
            SELECT
                CAST(strftime('%Y', takenAt, 'unixepoch', 'localtime') AS INTEGER),
                CAST(strftime('%m', takenAt, 'unixepoch', 'localtime') AS INTEGER),
                COUNT(*)
            FROM \(table)
            WHERE takenAt IS NOT NULL
            GROUP BY 1, 2
            ORDER BY 1, 2
        """, columnCount: 3)
        return rows.map { row in
            TimelineMonthCount(year: row[0], month: row[1], count: row[2])
        }
    }

    // Loads thumbnail manifests by original refs in one batch to keep sparse grid fetches efficient.
    func loadThumbnailsByOriginalRefs(_ refs: [String]) async throws -> [String: ThumbnailSetManifest] {
        guard !refs.isEmpty else { return [:] }
        let table = try await database.tableName(for: ThumbnailSetManifest.self)
        let placeholders = Array(repeating: "?", count: refs.count).joined(separator: ", ")
        let rows = try await database.query(ThumbnailSetManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE originalRef IN (\(placeholders))
        """, arguments: QueryArguments(refs))
        var result: [String: ThumbnailSetManifest] = [:]
        for row in rows {
            result[row.spec.originalRef] = row
        }
        return result
    }

    // Commits under the shared repository mutation lock so git writes cannot overlap pull/push operations.
    func createCommit(message: String, items: [GitCommitItem]) async throws {
        try await repository.withMutationLock {
            try await commitService.createCommit(message: message, items: items)
            try await syncEngine.syncAfterCommit(items: items)
        }
    }

    // Uploads binary payloads to LFS while preserving the existing git commit pipeline.
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSData(_ data: Data, for manifest: any Manifest, progressHandler: ((Int64, Int64) -> Void)?) async throws -> LFSPointer {
        try await commitService.addLFSData(data, for: manifest, progressHandler: progressHandler)
    }

    // Uploads one encrypted source file through GitCommitService so large originals avoid full in-memory upload buffers.
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSFileEncrypting(
        at fileURL: URL,
        dek: Data,
        oid: String,
        size: Int64,
        for manifest: any Manifest,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer {
        try await commitService.addLFSFileEncrypting(
            at: fileURL,
            dek: dek,
            oid: oid,
            size: size,
            for: manifest,
            progressHandler: progressHandler
        )
    }

    // Uploads one derived binary by explicit path components so multi-entry manifests can share one metadata document.
    @available(iOS 13.0, macOS 10.15, *)
    func addLFSData(
        _ data: Data,
        apiVersion: String,
        kind: String,
        name: String,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws -> LFSPointer {
        try await commitService.addLFSData(
            data,
            apiVersion: apiVersion,
            kind: kind,
            name: name,
            progressHandler: progressHandler
        )
    }

    // Forwards cancellation into commit/LFS services so UI cancel stops in-flight uploads quickly.
    func cancelActiveLFSUpload() {
        commitService.cancelActiveLFSUpload()
    }

    // Synchronizes the database with git HEAD, reporting hydration progress when available.
    func syncToHead(progressHandler: SyncProgressHandler? = nil) async throws {
        try await syncEngine.syncToHead(progressHandler: progressHandler)
    }

    // Finds an existing original by sha256 so uploads can perform content-based deduplication.
    func loadOriginalBySHA256(_ sha256: String) async throws -> OriginalManifest? {
        let table = try await database.tableName(for: OriginalManifest.self)
        return try await database.query(OriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE sha256 = ?
            LIMIT 1
        """, arguments: [sha256]).first
    }

    // Builds a localID-to-modifiedAt lookup for all uploaded originals so sync can skip unchanged assets early.
    func loadUploadedLocalIDs() async throws -> [String: String?] {
        let table = try await database.tableName(for: OriginalManifest.self)
        let originals = try await database.query(OriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
        """)
        var uploadedByLocalID: [String: String?] = [:]
        for original in originals {
            guard let localID = original.spec.localID else { continue }
            uploadedByLocalID[localID] = original.spec.modifiedAt
        }
        return uploadedByLocalID
    }
}
