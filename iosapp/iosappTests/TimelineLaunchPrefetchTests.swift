import Foundation
import LibGit2
import Testing
@testable import GitDB
@testable import iosapp

// Launch applies this snapshot instead of querying again. A stale or
// repeated hand-off would show a library the database no longer has.
@MainActor
struct TimelineLaunchPrefetchTests {
    private struct Fixture {
        let database: ManifestDatabase
        let databaseURL: URL
        let manifests: ManifestLoaderManager
        let june: Date
        let july: Date

        func photo(id: String, takenAt: Date?) -> OriginalManifest {
            OriginalManifest(
                id: id,
                localID: "local-\(id)",
                sha256: "sha-\(id)",
                path: "/tmp/\(id).jpg",
                filesize: 10,
                name: id,
                deviceSpace: "test-device",
                mediaType: "photo",
                width: 8,
                height: 8,
                modifiedAt: nil,
                duration: nil,
                mimeType: "image/jpeg",
                location: nil,
                isFavorite: false,
                isHidden: false,
                burstIdentifier: nil,
                takenAt: takenAt
            )
        }

        func close() async {
            try? await database.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }
    }

    private func makeFixture() throws -> Fixture {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let june = try #require(
            calendar.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12))
        )
        let july = try #require(
            calendar.date(from: DateComponents(year: 2024, month: 7, day: 15, hour: 12))
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-prefetch-\(UUID().uuidString).sqlite")
        let manifests = ManifestLoaderManager(
            notificationCenter: NotificationCenter(),
            databaseURL: url
        )
        return Fixture(
            database: try manifests.getDatabase(),
            databaseURL: url,
            manifests: manifests,
            june: june,
            july: july
        )
    }

    // Two dated photos plus one with no capture time. The undated photo
    // stays out of the timeline, and June is grouped separately from July.
    private func seed(_ fixture: Fixture) async throws {
        try await fixture.database.replaceAll(
            manifests: [
                fixture.photo(id: "june-a", takenAt: fixture.june),
                fixture.photo(id: "june-b", takenAt: fixture.june),
                fixture.photo(id: "july", takenAt: fixture.july),
                fixture.photo(id: "undated", takenAt: nil),
            ],
            commitHash: "seed"
        )
    }

    private func monthKey(_ count: TimelineMonthCount) -> String {
        "\(count.year)-\(count.month)-\(count.count)"
    }

    @Test func snapshotMatchesTheSeededRows() async throws {
        let fixture = try makeFixture()
        defer { Task { await fixture.close() } }
        try await seed(fixture)

        let prefetch = TimelineLaunchPrefetch()
        prefetch.start(database: fixture.database)
        let snapshot = await prefetch.take(database: fixture.database)

        #expect(snapshot?.totalCount == 3)
        #expect(snapshot?.monthCounts.map(monthKey) == ["2024-6-2", "2024-7-1"])
    }

    // A sync that commits while the count is in flight has to win.
    // Applying the snapshot would hide that write from the timeline.
    @Test func aWriteAfterStartDropsTheSnapshot() async throws {
        let fixture = try makeFixture()
        defer { Task { await fixture.close() } }
        try await seed(fixture)

        let prefetch = TimelineLaunchPrefetch()
        prefetch.start(database: fixture.database)
        try await fixture.database.applyMutation(
            added: [fixture.photo(id: "later", takenAt: fixture.july)],
            updated: [],
            removed: [],
            commitHash: "later"
        )

        let snapshot = await prefetch.take(database: fixture.database)
        #expect(snapshot == nil)
    }

    // The grid and a later reload must not both apply one snapshot.
    @Test func aSecondTakeReturnsNil() async throws {
        let fixture = try makeFixture()
        defer { Task { await fixture.close() } }
        try await seed(fixture)

        let prefetch = TimelineLaunchPrefetch()
        prefetch.start(database: fixture.database)
        let first = await prefetch.take(database: fixture.database)
        let second = await prefetch.take(database: fixture.database)

        #expect(first?.totalCount == 3)
        #expect(second == nil)
    }

    // A cache rebuilt at launch is a different instance. The snapshot
    // belongs to the one that was prefetched.
    @Test func aDifferentDatabaseReturnsNil() async throws {
        let fixture = try makeFixture()
        defer { Task { await fixture.close() } }
        try await seed(fixture)
        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-prefetch-\(UUID().uuidString).sqlite")
        let other = try ManifestLoaderManager(
            notificationCenter: NotificationCenter(),
            databaseURL: otherURL
        ).getDatabase()
        defer {
            Task {
                try? await other.close()
                try? FileManager.default.removeItem(at: otherURL)
            }
        }

        let prefetch = TimelineLaunchPrefetch()
        prefetch.start(database: fixture.database)
        let snapshot = await prefetch.take(database: other)

        #expect(snapshot == nil)
    }

    // The prefetch and the timeline must group the same rows. Two copies
    // of the SQL would drift.
    @Test func staticQueriesMatchTheInstanceMethods() async throws {
        let fixture = try makeFixture()
        defer { Task { await fixture.close() } }
        try await seed(fixture)

        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-prefetch-repo-\(UUID().uuidString)")
            .path
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        defer { try? FileManager.default.removeItem(atPath: repoPath) }
        let manager = DefaultManifestManager(
            repository: repository,
            deviceSpace: "test-device",
            lfsClient: GitLFS(serverURL: "http://test.invalid", router: .passthroughForTests()),
            database: fixture.database,
            registry: fixture.manifests.getRegistry()
        )

        let staticCount = try await DefaultManifestManager.countTimelineOriginals(
            database: fixture.database,
            scope: .all
        )
        let staticMonths = try await DefaultManifestManager.loadTimelineMonthCounts(
            database: fixture.database,
            scope: .all
        )
        let instanceCount = try await manager.countTimelineOriginals(scope: .all)
        let instanceMonths = try await manager.loadTimelineMonthCounts(scope: .all)

        #expect(staticCount == instanceCount)
        #expect(staticCount == 3)
        #expect(staticMonths.map(monthKey) == instanceMonths.map(monthKey))
        #expect(staticMonths.map(monthKey) == ["2024-6-2", "2024-7-1"])
    }
}
