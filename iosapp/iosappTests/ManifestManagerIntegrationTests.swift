import Foundation
import Testing
import LibGit2
@testable import GitDB
@testable import iosapp

// Verifies ManifestManager keeps git-first writes and database reads consistent in one call path.
@MainActor
@Suite(.serialized, .sharedAppState)
struct ManifestManagerIntegrationTests {
    // Shards manifest fixture names so integration tests follow production git layout.
    private func shardName(_ name: String) -> String {
        if name.count < 5 {
            return name
        }
        let first = String(name.prefix(2))
        let second = String(name.dropFirst(2).prefix(2))
        let rest = String(name.dropFirst(4))
        return "\(first)/\(second)/\(rest)"
    }
    // Creates the app registry shape used by manager queries.
    private func makeRegistry() -> ManifestRegistry {
        let registry = ManifestRegistry()
        registry.register(OriginalManifest.self) { reg in
            reg.column("takenAt", type: .real, nullable: true)
            reg.column("guessedTakenAt", type: .real, nullable: true)
            reg.column("mediaType", type: .text)
            reg.column("sha256", type: .text)
            reg.column("isFavorite", type: .integer)
            reg.column("isHidden", type: .integer)
            reg.column("latitude", type: .real, nullable: true)
            reg.column("longitude", type: .real, nullable: true)
            reg.index(on: ["takenAt", "id"], where: "takenAt IS NOT NULL")
            reg.index(on: ["latitude", "longitude"], where: "latitude IS NOT NULL")
            reg.index(on: ["sha256"])
            reg.extractColumns { manifest in
                [
                    "takenAt": manifest.spec.takenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "guessedTakenAt": manifest.spec.guessedTakenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    "mediaType": .string(manifest.spec.mediaType),
                    "sha256": .string(manifest.spec.sha256),
                    "isFavorite": .int(manifest.spec.isFavorite ? 1 : 0),
                    "isHidden": .int(manifest.spec.isHidden ? 1 : 0),
                    "latitude": manifest.spec.location.map { .double($0.latitude) } ?? .null,
                    "longitude": manifest.spec.location.map { .double($0.longitude) } ?? .null,
                ]
            }
        }
        return registry
    }

    // Generates a minimal original manifest YAML blob used for external git-commit fixtures.
    private func originalManifestYAML(id: String, takenAt: String?, guessedTakenAt: String?) -> String {
        let takenLine = takenAt.map { "  takenAt: \($0)\n" } ?? ""
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
        \(takenLine)\(guessedLine)status: {}
        """
    }

    // Bootstraps a real age-wrapped KEK epoch so syncToHead decrypt uses production identity.
    private func bootstrapEncryption(in repository: Repository) throws -> (kek: Data, epoch: Int, files: [(String, String)]) {
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "iosapp-tests")
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
        let manager = KEKEpochManager(repository: repository)
        let files = try manager.bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        let kek = try manager.loadKEK(epoch: 1)
        return (kek, 1, files)
    }

    // Encrypts fixture YAML so syncToHead rejects plaintext and decrypts envelopes.
    private func encryptManifest(_ yaml: String, kek: Data, epoch: Int) throws -> String {
        let encrypted = try EncryptionUtils.encryptAESGCM(plaintext: Data(yaml.utf8), key: kek)
        return """
        REPLYCANT-ENC-V1
        kek-epoch: \(epoch)
        ---
        \(encrypted.base64EncodedString())
        """
    }

    // Uses production encryption so syncAfterCommit can decrypt fixture commits.
    private func makeCommitService(repository: Repository) -> DefaultGitCommitService {
        DefaultGitCommitService(
            repository: repository,
            deviceSpace: "test-device",
            lfsClient: GitLFS(serverURL: "http://test.invalid", router: .passthroughForTests())
        )
    }

    // Creates a disposable repository/database pair for end-to-end manager behavior tests.
    private func makeFixture() throws -> (Repository, ManifestDatabase, ManifestRegistry, String, URL) {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-manager-repo-\(UUID().uuidString)")
            .path
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        // Production writes gitdb/version and the first KEK epoch together,
        // so a fixture without either is refused by write or hydrate paths.
        let bootstrap = try bootstrapEncryption(in: repository)
        try repository.createCommit(
            message: "seed database version",
            files: bootstrap.files
        )
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-manager-db-\(UUID().uuidString).sqlite")
        let registry = makeRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        return (repository, database, registry, repoPath, dbURL)
    }

    // Ensures createCommit writes git first and exposes manifests through database-backed read APIs.
    @Test func createCommitThenReadFromDatabase() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        let commitService = makeCommitService(repository: repository)
        let manager = DefaultManifestManager(repository: repository, database: database, commitService: commitService, registry: registry)

        let manifest = OriginalManifest(
            id: "img-1",
            localID: "local-img-1",
            sha256: "sha-img-1",
            path: "/tmp/img-1.jpg",
            filesize: 2048,
            name: "img-1",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            takenAt: Date(timeIntervalSince1970: 20),
            clientCTime: nil,
            guessedTakenAt: Date(timeIntervalSince1970: 20)
        )

        try await manager.createCommit(message: "add image", items: [.manifest(manifest)])

        let loadedByID: OriginalManifest? = try await manager.loadManifest(deviceSpace: "test-device", id: "img-1")
        #expect(loadedByID?.spec.sha256 == "sha-img-1")

        let timeline: [OriginalManifest] = try await manager.loadAllManifests(deviceSpace: "test-device")
        #expect(timeline.map(\.id) == ["img-1"])
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
    }

    // Ensures syncToHead hydrates the database before UI read paths consume manifest data.
    @Test func syncToHeadPopulatesDatabaseForInitialReadFlow() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        let activeKEK = try KEKEpochManager(repository: repository).loadCurrentKEK()
        let encryptedSeed = try encryptManifest(
            originalManifestYAML(id: "img-1", takenAt: "2024-01-01T10:00:00Z", guessedTakenAt: "2024-01-01T10:00:00Z"),
            kek: activeKEK.kek,
            epoch: activeKEK.epoch
        )
        try repository.createCommit(
            message: "seed",
            files: [
                ("manifests/test-device/media.replycant.com/v1alpha1/Original/\(shardName("img-1")).yaml", encryptedSeed)
            ]
        )

        let commitService = makeCommitService(repository: repository)
        let manager = DefaultManifestManager(repository: repository, database: database, commitService: commitService, registry: registry)

        let beforeSync: [OriginalManifest] = try await manager.loadAllManifests(deviceSpace: "test-device")
        #expect(beforeSync.isEmpty)

        var progressEvents: [(String, Int, Int)] = []
        try await manager.syncToHead { phase, loaded, total in
            progressEvents.append((phase, loaded, total))
        }

        let afterSync: [OriginalManifest] = try await manager.loadAllManifests(deviceSpace: "test-device")
        #expect(afterSync.map(\.id) == ["img-1"])
        #expect(try await database.readSyncedCommitHash() == repository.headOID())
        #expect(progressEvents.contains { $0.0 == "Reading manifests" })
    }

    // Ensures timeline month aggregation returns grouped year/month counts for month-sidebar navigation.
    @Test func loadTimelineMonthCountsGroupsByYearAndMonth() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        let commitService = makeCommitService(repository: repository)
        let manager = DefaultManifestManager(repository: repository, database: database, commitService: commitService, registry: registry)

        let janA = OriginalManifest(
            id: "jan-a",
            localID: "local-jan-a",
            sha256: "sha-jan-a",
            path: "/tmp/jan-a.jpg",
            filesize: 2048,
            name: "jan-a",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            takenAt: Date(timeIntervalSince1970: 1_705_320_000),
            clientCTime: nil,
            guessedTakenAt: Date(timeIntervalSince1970: 1_705_320_000) // 2024-01-15T12:00:00Z
        )
        let janB = OriginalManifest(
            id: "jan-b",
            localID: "local-jan-b",
            sha256: "sha-jan-b",
            path: "/tmp/jan-b.jpg",
            filesize: 2048,
            name: "jan-b",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            takenAt: Date(timeIntervalSince1970: 1_706_140_800),
            clientCTime: nil,
            guessedTakenAt: Date(timeIntervalSince1970: 1_706_140_800) // 2024-01-25T00:00:00Z
        )
        let marA = OriginalManifest(
            id: "mar-a",
            localID: "local-mar-a",
            sha256: "sha-mar-a",
            path: "/tmp/mar-a.jpg",
            filesize: 2048,
            name: "feb-a",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            takenAt: Date(timeIntervalSince1970: 1_709_164_800),
            clientCTime: nil,
            guessedTakenAt: Date(timeIntervalSince1970: 1_709_164_800) // 2024-02-29T00:00:00Z
        )
        let excluded = OriginalManifest(
            id: "excluded",
            localID: "local-excluded",
            sha256: "sha-excluded",
            path: "/tmp/excluded.jpg",
            filesize: 2048,
            name: "excluded",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            takenAt: nil,
            clientCTime: nil,
            guessedTakenAt: nil
        )

        try await manager.createCommit(
            message: "seed months",
            items: [.manifest(janA), .manifest(janB), .manifest(marA), .manifest(excluded)]
        )

        let monthCounts = try await manager.loadTimelineMonthCounts()
        #expect(monthCounts.count == 2)
        #expect(monthCounts[0].year == 2024 && monthCounts[0].month == 1 && monthCounts[0].count == 2)
        #expect(monthCounts[1].year == 2024 && monthCounts[1].month == 2 && monthCounts[1].count == 1)
    }

    // Ensures timeline reads exclude originals without takenAt even if guessedTakenAt exists.
    @Test func timelineQueriesExcludeOriginalsWithoutTakenAt() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        let commitService = makeCommitService(repository: repository)
        let manager = DefaultManifestManager(repository: repository, database: database, commitService: commitService, registry: registry)

        let included = OriginalManifest(
            id: "included",
            localID: "local-included",
            sha256: "sha-included",
            path: "/tmp/included.jpg",
            filesize: 2048,
            name: "included",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            takenAt: Date(timeIntervalSince1970: 100),
            clientCTime: nil,
            guessedTakenAt: Date(timeIntervalSince1970: 100)
        )
        let excluded = OriginalManifest(
            id: "excluded",
            localID: "local-excluded",
            sha256: "sha-excluded",
            path: "/tmp/excluded.jpg",
            filesize: 2048,
            name: "excluded",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            takenAt: nil,
            clientCTime: Date(timeIntervalSince1970: 200),
            guessedTakenAt: Date(timeIntervalSince1970: 200)
        )

        try await manager.createCommit(
            message: "seed timeline takenAt filter",
            items: [.manifest(included), .manifest(excluded)]
        )

        #expect(try await manager.countTimelineOriginals() == 1)
        #expect(try await manager.loadTimelinePage(offset: 0, limit: 10).map(\.id) == ["included"])
        #expect(try await manager.loadTimelineMonthCounts().count == 1)
    }

    // Photo uploads must share GitDB's version guard so an
    // unsupported gitdb/version cannot be written through ManifestManager.
    @Test func createCommitRefusesUnsupportedDatabaseVersion() async throws {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-manager-unsupported-\(UUID().uuidString)")
            .path
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        try repository.createCommit(
            message: "unsupported database version",
            files: [("gitdb/version", "2\n")]
        )
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-manager-unsupported-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let registry = makeRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        let commitService = makeCommitService(repository: repository)
        let manager = DefaultManifestManager(
            repository: repository,
            database: database,
            commitService: commitService,
            registry: registry
        )

        let manifest = OriginalManifest(
            id: "blocked",
            localID: "local-blocked",
            sha256: "sha-blocked",
            path: "/tmp/blocked.jpg",
            filesize: 2048,
            name: "blocked",
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil
        )

        await #expect(throws: DatabaseVersionError.unsupported(found: 2, required: 1)) {
            try await manager.createCommit(message: "should fail", items: [.manifest(manifest)])
        }
    }

    // Place grids and the map read the same timeline, narrowed by location,
    // so paging, month jumps, and the point list must agree on membership.
    @Test func locationScopeFiltersTimelineReadsAndGeotaggedPoints() async throws {
        let (repository, database, registry, repoPath, _) = try makeFixture()
        defer {
            try? FileManager.default.removeItem(atPath: repoPath)
        }

        let commitService = makeCommitService(repository: repository)
        let manager = DefaultManifestManager(
            repository: repository,
            database: database,
            commitService: commitService,
            registry: registry
        )

        let stockholmA = locatedOriginal(
            id: "stockholm-a",
            takenAt: Date(timeIntervalSince1970: 1_705_320_000),
            latitude: 59.33,
            longitude: 18.06
        )
        let newYork = locatedOriginal(
            id: "new-york",
            takenAt: Date(timeIntervalSince1970: 1_706_140_800),
            latitude: 40.71,
            longitude: -74.0
        )
        let stockholmB = locatedOriginal(
            id: "stockholm-b",
            takenAt: Date(timeIntervalSince1970: 1_709_164_800),
            latitude: 59.34,
            longitude: 18.07
        )
        let noLocation = locatedOriginal(
            id: "no-location",
            takenAt: Date(timeIntervalSince1970: 1_709_164_800),
            latitude: nil,
            longitude: nil
        )
        let noTakenAt = locatedOriginal(
            id: "no-taken-at",
            takenAt: nil,
            latitude: 59.33,
            longitude: 18.06
        )

        try await manager.createCommit(
            message: "seed locations",
            items: [
                .manifest(stockholmA),
                .manifest(newYork),
                .manifest(stockholmB),
                .manifest(noLocation),
                .manifest(noTakenAt),
            ]
        )

        let stockholm = TimelineScope.area(GeoBounds(
            minLatitude: 59,
            maxLatitude: 60,
            minLongitude: 18,
            maxLongitude: 19
        ))

        #expect(try await manager.countTimelineOriginals(scope: stockholm) == 2)
        #expect(try await manager.countTimelineOriginals(scope: .geotagged) == 3)
        #expect(try await manager.countTimelineOriginals(scope: .all) == 4)

        #expect(try await manager.loadTimelinePage(offset: 0, limit: 10, scope: stockholm).map(\.id) == ["stockholm-a", "stockholm-b"])

        let beforeB = TimelineCursor(date: Date(timeIntervalSince1970: 1_709_164_800), id: "stockholm-b")
        #expect(try await manager.loadTimelinePage(before: beforeB, limit: 10, scope: stockholm).map(\.id) == ["stockholm-a"])

        let afterA = TimelineCursor(date: Date(timeIntervalSince1970: 1_705_320_000), id: "stockholm-a")
        #expect(try await manager.loadTimelinePage(after: afterA, limit: 10, scope: stockholm).map(\.id) == ["stockholm-b"])

        let months = try await manager.loadTimelineMonthCounts(scope: stockholm)
        #expect(months.count == 2)
        #expect(months[0].year == 2024 && months[0].month == 1 && months[0].count == 1)
        #expect(months[1].year == 2024 && months[1].month == 2 && months[1].count == 1)

        let points = try await manager.loadGeotaggedPoints()
        #expect(Set(points.map(\.id)) == ["stockholm-a", "stockholm-b", "new-york"])
        #expect(points.first { $0.id == "stockholm-a" }?.latitude == 59.33)
        #expect(points.first { $0.id == "stockholm-a" }?.longitude == 18.06)

        let loaded = try await manager.loadOriginals(ids: ["new-york", "missing"])
        #expect(loaded.map(\.id) == ["new-york"] || loaded.map(\.id) == ["new-york"].sorted())
        #expect(Set(loaded.map(\.id)) == ["new-york"])
    }

    // Builds one original with an optional GPS fix so location-scope tests
    // can mix placed, unplaced, and undated media.
    private func locatedOriginal(
        id: String,
        takenAt: Date?,
        latitude: Double?,
        longitude: Double?
    ) -> OriginalManifest {
        let location: OriginalManifest.Spec.Location?
        if let latitude, let longitude {
            location = .init(latitude: latitude, longitude: longitude, altitude: nil)
        } else {
            location = nil
        }
        return OriginalManifest(
            id: id,
            localID: "local-\(id)",
            sha256: "sha-\(id)",
            path: "/tmp/\(id).jpg",
            filesize: 2048,
            name: id,
            deviceSpace: "test-device",
            mediaType: "photo",
            width: 100,
            height: 100,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: location,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            takenAt: takenAt,
            clientCTime: nil,
            guessedTakenAt: takenAt
        )
    }
}
