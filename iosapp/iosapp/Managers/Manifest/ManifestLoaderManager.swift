import Foundation
import GitDB

// Owns the shared manifest database instance so all managers read one consistent cache.
@MainActor
final class ManifestLoaderManager {
    static let shared = ManifestLoaderManager()

    // Announces that the shared database was dropped so managers holding
    // objects derived from it rebind. Writes reach a replacement instance
    // through its own change stream, so a stale holder is not merely reading
    // old rows, it stops receiving updates entirely.
    static let databaseDidInvalidateNotification = Notification.Name(
        "ManifestLoaderManager.databaseDidInvalidate"
    )

    private var database: GitDB.ManifestDatabase?
    private var registry: GitDB.ManifestRegistry?
    private let notificationCenter: NotificationCenter

    // The notification center is injectable so a test can verify the broadcast
    // on a private center. Every live manager in the process reacts to this
    // notification by reloading, so announcing it on the default center from a
    // test stampedes unrelated suites running in parallel.
    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    // Returns the shared manifest registry with app schema registrations.
    func getRegistry() -> GitDB.ManifestRegistry {
        if let registry {
            return registry
        }
        let registry = GitDB.ManifestRegistry()
        registerSchema(in: registry)
        self.registry = registry
        return registry
    }

    // Returns a shared database instance to keep all manifest reads and writes in sync.
    func getDatabase() throws -> GitDB.ManifestDatabase {
        if let database {
            AppSignposts.event("ManifestDatabaseReused")
            return database
        }
        let databaseOpenSignpost = AppSignposts.begin("ManifestDatabaseOpen")
        do {
            let database = try GitDB.ManifestDatabase(registry: getRegistry())
            AppSignposts.end("ManifestDatabaseOpen", databaseOpenSignpost)
            self.database = database
            return database
        } catch {
            AppSignposts.end("ManifestDatabaseOpen", databaseOpenSignpost)
            throw error
        }
    }

    // Drops the shared instance so the next access recreates database connections cleanly.
    func clearLoader() {
        database = nil
        registry = nil
        broadcastInvalidation()
    }

    // Removes all cached rows while preserving the sqlite file and connection.
    func clearCache() async throws {
        guard let database else { return }
        try await database.clearAll()
    }

    // Deletes the sqlite file so reset flows start from a cold cache on next launch.
    func deleteDatabaseFile() throws {
        let url = GitDB.ManifestDatabase.defaultDatabaseURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        database = nil
        registry = nil
        broadcastInvalidation()
    }

    private func broadcastInvalidation() {
        notificationCenter.post(
            name: Self.databaseDidInvalidateNotification,
            object: nil
        )
    }

    // Exposes database lifecycle state for reset-flow tests.
    var hasCachedLoaderForTesting: Bool {
        database != nil
    }

    // Registers app manifest kinds and SQL projection columns used by timeline and dedup queries.
    private func registerSchema(in registry: GitDB.ManifestRegistry) {
        registry.register(OriginalManifest.self) { reg in
            reg.column("takenAt", type: .real, nullable: true)
            reg.column("guessedTakenAt", type: .real, nullable: true)
            reg.column("mediaType", type: .text)
            reg.column("sha256", type: .text)
            reg.column("isFavorite", type: .integer)
            reg.column("isHidden", type: .integer)
            reg.index(on: ["takenAt", "id"], where: "takenAt IS NOT NULL")
            reg.index(on: ["mediaType"])
            reg.index(on: ["sha256"])
            reg.extractColumns { manifest in
                [
                    "takenAt": manifest.spec.takenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "guessedTakenAt": manifest.spec.guessedTakenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "mediaType": .string(manifest.spec.mediaType),
                    "sha256": .string(manifest.spec.sha256),
                    "isFavorite": .int(manifest.spec.isFavorite ? 1 : 0),
                    "isHidden": .int(manifest.spec.isHidden ? 1 : 0),
                ]
            }
        }
        registry.register(ThumbnailSetManifest.self) { reg in
            reg.column("originalRef", type: .text)
            reg.index(on: ["originalRef"])
            reg.extractColumns { manifest in
                [
                    "originalRef": .string(manifest.spec.originalRef),
                ]
            }
        }
    }
}
