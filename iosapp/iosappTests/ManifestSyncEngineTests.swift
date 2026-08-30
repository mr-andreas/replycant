import Foundation
import Testing
import LibGit2
@testable import GitDB
@testable import iosapp

// Verifies commit-diff synchronization keeps the manifest database aligned with git HEAD.
@MainActor
@Suite(.sharedAppState)
struct ManifestSyncEngineTests {
    // Shards manifest fixture names so sync tests exercise the production tree layout.
    private func shardName(_ name: String) -> String {
        if name.count < 5 {
            return name
        }
        let first = String(name.prefix(2))
        let second = String(name.dropFirst(2).prefix(2))
        let rest = String(name.dropFirst(4))
        return "\(first)/\(second)/\(rest)"
    }
    // Creates the app registry shape used by sync and timeline queries.
    private func makeRegistry() -> ManifestRegistry {
        let registry = ManifestRegistry()
        registry.register(OriginalManifest.self) { reg in
            reg.column("guessedTakenAt", type: .real, nullable: true)
            reg.column("sha256", type: .text)
            reg.index(on: ["guessedTakenAt", "id"], where: "guessedTakenAt IS NOT NULL")
            reg.extractColumns { manifest in
                [
                    "guessedTakenAt": manifest.spec.guessedTakenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "sha256": .string(manifest.spec.sha256),
                ]
            }
        }
        return registry
    }

    // Builds a temporary repository and database pair for sync engine tests.
    private func makeFixture() throws -> (Repository, ManifestDatabase, ManifestRegistry, repoPath: String, dbURL: URL) {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-sync-repo-\(UUID().uuidString)")
            .path
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-sync-db-\(UUID().uuidString).sqlite")
        let registry = makeRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        return (repository, database, registry, repoPath, dbURL)
    }

    // Bootstraps a real age-wrapped KEK epoch so GitDB sync decrypt uses Keychain identity.
    private func bootstrapEncryption(in repository: Repository) throws -> (kek: Data, epoch: Int, files: [(String, String)]) {
        try GitDB.ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "iosapp-tests")
        let agePublicKey = try GitDB.ClientIdentityManager.shared.agePublicKey()
        let manager = GitDB.KEKEpochManager(repository: repository)
        let files = try manager.bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        let kek = try manager.loadKEK(epoch: 1)
        return (kek, 1, files)
    }

    // Encrypts fixture YAML with the active KEK so syncToHead exercises real decrypt paths.
    private func encryptManifest(_ yaml: String, kek: Data, epoch: Int) throws -> String {
        let encrypted = try GitDB.EncryptionUtils.encryptAESGCM(plaintext: Data(yaml.utf8), key: kek)
        return """
        REPLYCANT-ENC-V1
        kek-epoch: \(epoch)
        ---
        \(encrypted.base64EncodedString())
        """
    }

    // Generates a minimal original manifest YAML blob used by commit fixtures.
    private func originalManifestYAML(id: String, guessedTakenAt: String?) -> String {
        let guessedLine = guessedTakenAt.map { "  guessedTakenAt: \($0)\n" } ?? ""
        return """
        apiVersion: media.replycant.com/v1alpha1
        kind: Original
        metadata:
          name: \(id)
          deviceSpace: test-device
        spec:
          id: \(id)
          sha256: sha-\(id)
          path: /tmp/\(id).jpg
          filesize: 2048
          mediaType: photo
          width: 100
          height: 100
          isFavorite: false
          isHidden: false
          createdAt: 2024-01-01T00:00:00Z
        \(guessedLine)status: {}
        """
    }

    // Ensures first sync fully hydrates database and emits progress updates during hydration.
    @Test func syncToHeadPerformsFullHydrationWithProgress() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        let bootstrap = try bootstrapEncryption(in: repository)
        try repository.createCommit(
            message: "seed",
            files: bootstrap.files + [
                ("manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("a")).yaml", try encryptManifest(originalManifestYAML(id: "a", guessedTakenAt: "2024-01-01T10:00:00Z"), kek: bootstrap.kek, epoch: bootstrap.epoch)),
                ("manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("b")).yaml", try encryptManifest(originalManifestYAML(id: "b", guessedTakenAt: nil), kek: bootstrap.kek, epoch: bootstrap.epoch)),
            ]
        )

        let engine = ManifestSyncEngine(repository: repository, database: database, registry: registry)
        var progressEvents: [(String, Int, Int)] = []
        try await engine.syncToHead { phase, loaded, total in
            progressEvents.append((phase, loaded, total))
        }

        let table = try await database.tableName(for: OriginalManifest.self)
        let timeline = try await database.query(OriginalManifest.self, sql: """
            SELECT data
            FROM \(table)
            WHERE guessedTakenAt IS NOT NULL
            ORDER BY guessedTakenAt ASC, id ASC
        """)
        #expect(timeline.map(\.id) == ["a"])
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
        #expect(progressEvents.contains { $0.0 == "Reading manifests" })
        #expect(progressEvents.contains { event in event.0 == "Updating database" && event.1 == 1 && event.2 == 1 })
    }
}
