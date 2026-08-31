import Foundation
import GRDB
import Combine
import OSLog

public typealias QueryArguments = StatementArguments

// Emits database signposts so cold-start profiling can attribute SQLite open and query phases.
private enum ManifestDatabaseSignposts {
    private static let logger = Logger(subsystem: "com.replycant.gitdb", category: "PointsOfInterest")
    private static let signposter = OSSignposter(logger: logger)

    // Starts one database signposted interval.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    // Ends one previously started database signposted interval.
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}

// Describes one incremental manifest transition for subscribers that react to sync updates.
public struct ManifestMutation {
    public let added: [any Manifest]
    public let updated: [any Manifest]
    public let removed: [any Manifest]

    public init(added: [any Manifest], updated: [any Manifest], removed: [any Manifest]) {
        self.added = added
        self.updated = updated
        self.removed = removed
    }
}

// Distinguishes incremental database updates from full cache replacement events.
public enum ManifestDatabaseChange {
    case incremental(ManifestMutation)
    case fullReplace
}

// Stores manifests in a single SQLite database with per-kind tables generated from registrations.
public actor ManifestDatabase {
    // Namespaces all SQL identifiers and metadata keys used by the manifest cache.
    private enum Constants {
        static let databaseFilename = "replycant-manifest-cache.sqlite"
        static let syncedCommitHashKey = "syncedCommitHash"
        static let cacheFormatVersionKey = "cacheFormatVersion"
        static let defaultCacheFormatVersion = 0
    }

    private let dbQueue: DatabaseQueue
    private let registry: ManifestRegistry
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public nonisolated let changes = PassthroughSubject<ManifestDatabaseChange, Never>()

    // Initializes the database and migrations so all callers share one durable schema.
    public init(databaseURL: URL? = nil, registry: ManifestRegistry) throws {
        let path = databaseURL ?? Self.defaultDatabaseURL()
        let openSignpost = ManifestDatabaseSignposts.begin("ManifestSQLiteOpen")
        do {
            self.dbQueue = try DatabaseQueue(path: path.path)
            ManifestDatabaseSignposts.end("ManifestSQLiteOpen", openSignpost)
        } catch {
            ManifestDatabaseSignposts.end("ManifestSQLiteOpen", openSignpost)
            throw error
        }

        self.registry = registry
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let migrateSignpost = ManifestDatabaseSignposts.begin("ManifestMigrate")
        do {
            try Self.migrate(dbQueue: dbQueue)
            ManifestDatabaseSignposts.end("ManifestMigrate", migrateSignpost)
        } catch {
            ManifestDatabaseSignposts.end("ManifestMigrate", migrateSignpost)
            throw error
        }

        let tableSetupSignpost = ManifestDatabaseSignposts.begin("ManifestEnsureRegisteredTables")
        do {
            try ensureRegisteredTables()
            ManifestDatabaseSignposts.end("ManifestEnsureRegisteredTables", tableSetupSignpost)
        } catch {
            ManifestDatabaseSignposts.end("ManifestEnsureRegisteredTables", tableSetupSignpost)
            throw error
        }
    }

    // Resolves the default cache location under the app's documents directory.
    public static func defaultDatabaseURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent(Constants.databaseFilename)
    }

    // Creates required metadata tables that are independent of registered manifest kinds.
    private static func migrate(dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("create_manifest_cache_v2") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
            """)
        }
        try migrator.migrate(dbQueue)
    }

    // Ensures all registered kind tables and indexes exist before query or mutation operations.
    private func ensureRegisteredTables() throws {
        let registrations = registry.allRegistrations()
        try dbQueue.write { db in
            for registration in registrations {
                try createTableIfNeeded(db: db, registration: registration)
                try createIndexesIfNeeded(db: db, registration: registration)
            }
        }
    }

    // Creates one registered kind table with base columns plus extracted columns.
    private func createTableIfNeeded(db: Database, registration: ManifestRegistry.Registration) throws {
        var columnSQL = [
            "id TEXT PRIMARY KEY NOT NULL",
            "deviceSpace TEXT NOT NULL",
            "data BLOB NOT NULL",
        ]
        columnSQL.append(contentsOf: registration.columns.map { column in
            "\(column.name) \(column.sqlType)\(column.nullable ? "" : " NOT NULL")"
        })
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS \(registration.tableName) (
                \(columnSQL.joined(separator: ",\n"))
            );
        """)
    }

    // Creates all declared indexes for one registered kind table.
    private func createIndexesIfNeeded(db: Database, registration: ManifestRegistry.Registration) throws {
        for (index, definition) in registration.indexes.enumerated() {
            guard !definition.columns.isEmpty else { continue }
            let indexName = "\(registration.tableName)_idx_\(index)"
            var sql = """
                CREATE INDEX IF NOT EXISTS \(indexName)
                ON \(registration.tableName)(\(definition.columns.joined(separator: ", ")))
            """
            if let whereClause = definition.whereClause, !whereClause.isEmpty {
                sql += " WHERE \(whereClause)"
            }
            sql += ";"
            try db.execute(sql: sql)
        }
    }

    // Returns the commit hash currently mirrored by the database, or nil on first sync.
    func readSyncedCommitHash() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM sync_metadata WHERE key = ?",
                arguments: [Constants.syncedCommitHashKey]
            )
        }
    }

    // Advances only the synced-commit checkpoint when manifest rows are already converged.
    func writeSyncedCommitHashOnly(_ commitHash: String) throws {
        try dbQueue.write { db in
            try writeSyncedCommitHash(commitHash, db: db)
        }
    }

    // Returns the format the cache was last built from so a later
    // gitdb/version bump can force full rehydration instead of a
    // garbage incremental diff. Missing rows mean format 0, the
    // in-code stand-in for caches built before the marker existed.
    func readCacheFormatVersion() throws -> Int {
        try dbQueue.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT value FROM sync_metadata WHERE key = ?",
                arguments: [Constants.cacheFormatVersionKey]
            ), let version = Int(raw), version >= 0 else {
                return Constants.defaultCacheFormatVersion
            }
            return version
        }
    }

    // Lets tests plant a stale cache format so a later sync can prove
    // it forces full rehydration without bumping the compiled pin.
    func writeCacheFormatVersionOnly(_ version: Int) throws {
        try dbQueue.write { db in
            try writeCacheFormatVersion(version, db: db)
        }
    }

    // Replaces all registered kind tables in one transaction for initial hydration or recovery.
    func replaceAll(
        manifests: [any Manifest],
        commitHash: String,
        cacheFormatVersion: Int = 0
    ) throws {
        try ensureRegisteredTables()
        let registrations = registry.allRegistrations()
        let manifestsByKind = Dictionary(grouping: manifests, by: \.kindValue)
        try dbQueue.write { db in
            for registration in registrations {
                try db.execute(sql: "DELETE FROM \(registration.tableName)")
                try upsertManifests(manifestsByKind[registration.kind] ?? [], registration: registration, db: db)
            }
            try writeSyncedCommitHash(commitHash, db: db)
            try writeCacheFormatVersion(cacheFormatVersion, db: db)
        }
        changes.send(.fullReplace)
    }

    // Applies one incremental mutation atomically so reads never observe partial transition state.
    func applyMutation(
        added: [any Manifest],
        updated: [any Manifest],
        removed: [any Manifest],
        commitHash: String,
        cacheFormatVersion: Int = 0
    ) throws {
        try ensureRegisteredTables()
        let removedByKind = Dictionary(grouping: removed, by: \.kindValue)
        let upsertedByKind = Dictionary(grouping: added + updated, by: \.kindValue)
        try dbQueue.write { db in
            for (kind, entries) in removedByKind {
                guard let registration = registry.registration(forKind: kind) else { continue }
                try deleteManifests(ids: entries.map(\.id), registration: registration, db: db)
            }
            for (kind, manifestsForKind) in upsertedByKind {
                guard let registration = registry.registration(forKind: kind) else { continue }
                try upsertManifests(manifestsForKind, registration: registration, db: db)
            }
            try writeSyncedCommitHash(commitHash, db: db)
            try writeCacheFormatVersion(cacheFormatVersion, db: db)
        }
        changes.send(.incremental(ManifestMutation(added: added, updated: updated, removed: removed)))
    }

    // Executes one query and decodes the `data` payload into typed manifests.
    public func query<T: Manifest>(
        _ type: T.Type,
        sql: String,
        arguments: QueryArguments = QueryArguments()
    ) throws -> [T] {
        try ensureRegisteredTables()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.map { row in
                guard let payload: Data = row["data"] else {
                    throw NotSupportedError("Query for \(type.kind) must include a data column")
                }
                return try decoder.decode(T.self, from: payload)
            }
        }
    }

    // Executes one query expected to return a scalar count.
    public func queryCount(
        sql: String,
        arguments: QueryArguments = QueryArguments()
    ) throws -> Int {
        let countSignpost = ManifestDatabaseSignposts.begin("ManifestQueryCount")
        defer {
            ManifestDatabaseSignposts.end("ManifestQueryCount", countSignpost)
        }
        try ensureRegisteredTables()
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    // Executes one query that projects integer columns for aggregate/index-style reads without decoding manifests.
    public func queryIntRows(
        sql: String,
        columnCount: Int,
        arguments: QueryArguments = QueryArguments()
    ) throws -> [[Int]] {
        guard columnCount > 0 else { return [] }
        try ensureRegisteredTables()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                (0..<columnCount).map { columnIndex in
                    if let intValue: Int = row[columnIndex] {
                        return intValue
                    }
                    if let doubleValue: Double = row[columnIndex] {
                        return Int(doubleValue)
                    }
                    return 0
                }
            }
        }
    }

    // Returns true when a manifest row already exists for one kind/id key.
    func manifestExists(kind: String, id: String) throws -> Bool {
        try ensureRegisteredTables()
        guard let registration = registry.registration(forKind: kind) else {
            return false
        }
        return try dbQueue.read { db in
            let result = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM \(registration.tableName) WHERE id = ? LIMIT 1",
                arguments: [id]
            )
            return result != nil
        }
    }

    // Releases the GRDB queue so wipe paths can unlink the sqlite file
    // without leaving a live descriptor on a deleted vnode.
    public func close() throws {
        try dbQueue.close()
    }

    // Deletes all stored rows to support explicit app-level reset flows.
    public func clearAll() throws {
        let registrations = registry.allRegistrations()
        try dbQueue.write { db in
            for registration in registrations {
                try db.execute(sql: "DELETE FROM \(registration.tableName)")
            }
            try db.execute(sql: "DELETE FROM sync_metadata")
        }
        changes.send(.fullReplace)
    }

    // Resolves the generated table name for one registered manifest type.
    public func tableName<T: Manifest>(for type: T.Type) throws -> String {
        try registry.tableName(for: type)
    }

    // Upserts a manifest batch inside an existing transaction using registered column extractors.
    private func upsertManifests(
        _ manifests: [any Manifest],
        registration: ManifestRegistry.Registration,
        db: Database
    ) throws {
        guard !manifests.isEmpty else { return }
        let dynamicColumns = registration.columns.map(\.name)
        let allColumns = ["id", "deviceSpace", "data"] + dynamicColumns
        let placeholders = Array(repeating: "?", count: allColumns.count).joined(separator: ", ")
        let updateClause = allColumns
            .filter { $0 != "id" }
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
        let statement = try db.makeStatement(sql: """
            INSERT INTO \(registration.tableName)(\(allColumns.joined(separator: ", ")))
            VALUES(\(placeholders))
            ON CONFLICT(id) DO UPDATE SET
                \(updateClause)
        """)

        for manifest in manifests {
            let payload = try encoder.encode(AnyEncodableManifest(manifest))
            let extracted = try registration.extract(manifest)
            var arguments: [DatabaseValueConvertible?] = [manifest.id, manifest.deviceSpaceValue, payload]
            for column in registration.columns {
                arguments.append(databaseValue(for: extracted[column.name] ?? .null))
            }
            try statement.execute(arguments: StatementArguments(arguments))
        }
    }

    // Deletes manifests in bulk inside an existing transaction for incremental sync efficiency.
    private func deleteManifests(ids: [String], registration: ManifestRegistry.Registration, db: Database) throws {
        guard !ids.isEmpty else { return }
        let statement = try db.makeStatement(sql: "DELETE FROM \(registration.tableName) WHERE id = ?")
        for id in ids {
            try statement.execute(arguments: [id])
        }
    }

    // Persists the synced commit hash checkpoint in the current transaction.
    private func writeSyncedCommitHash(_ hash: String, db: Database) throws {
        try writeMetadata(key: Constants.syncedCommitHashKey, value: hash, db: db)
    }

    // Persists the format the current cache snapshot was built from.
    private func writeCacheFormatVersion(_ version: Int, db: Database) throws {
        try writeMetadata(
            key: Constants.cacheFormatVersionKey,
            value: String(version),
            db: db
        )
    }

    // Upserts one sync_metadata row so hash and format stay in the
    // same key-value table without a schema migration.
    private func writeMetadata(key: String, value: String, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_metadata(key, value)
                VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    // Converts registered SQL values into GRDB-bindable values.
    private func databaseValue(for value: ManifestSQLValue) -> DatabaseValueConvertible? {
        switch value {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .data(let value): return value
        case .null: return nil
        }
    }
}

// Encodes existential manifest values by delegating to their concrete Encodable implementation.
private struct AnyEncodableManifest: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ manifest: any Manifest) {
        self.encodeClosure = { encoder in
            try manifest.encode(to: encoder)
        }
    }

    // Forwards encoding to the concrete manifest value captured at initialization.
    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
