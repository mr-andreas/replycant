import Combine
import Foundation
import Testing
@testable import GitDB
@testable import iosapp

// Covers recovery when the shared manifest database is replaced underneath
// long-lived managers.
//
// Reset flows delete the sqlite file and drop the shared ManifestDatabase, but
// TimelineManager caches a manifest loader built from that instance plus a
// subscription to its change stream. Writes to the replacement instance are
// published on a different stream, so without an invalidation broadcast the
// timeline reads a discarded handle, never sees the rebuilt rows, and stays
// empty until the app is relaunched.
@MainActor
struct ManifestDatabaseInvalidationTests {
    // Counts broadcasts from a notification observer. The callback is not
    // isolated to the test actor, so the tally needs reference semantics.
    private final class InvalidationCounter: @unchecked Sendable {
        var count = 0
    }

    // Observes one loader's broadcasts on a center of its own.
    //
    // The loader under test is a fresh instance rather than the shared one:
    // announcing invalidation on the default center makes every live manager in
    // the process reload, which stampedes suites running in parallel.
    private func countInvalidations(
        during action: (ManifestLoaderManager) async throws -> Void
    ) async rethrows -> Int {
        let isolatedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "replycant-invalidation-\(UUID().uuidString).sqlite"
            )
        defer { try? FileManager.default.removeItem(at: isolatedURL) }

        let center = NotificationCenter()
        let loader = ManifestLoaderManager(
            notificationCenter: center,
            databaseURL: isolatedURL
        )
        let counter = InvalidationCounter()
        let token = center.addObserver(
            forName: ManifestLoaderManager.databaseDidInvalidateNotification,
            object: nil,
            queue: nil
        ) { _ in
            counter.count += 1
        }
        defer { center.removeObserver(token) }

        try await action(loader)
        return counter.count
    }

    // Dropping the shared instance must be announced: callers that already hold
    // the old database would otherwise keep using it indefinitely.
    @Test func clearLoaderBroadcastsInvalidation() async {
        let count = await countInvalidations { loader in
            loader.clearLoader()
        }

        #expect(count == 1)
    }

    // A private loader must not unlink the process-wide cache. Parallel
    // suites keep an open GRDB connection on that file, and deleting it
    // produced SQLite error 10 during recovery hydration.
    @Test func deleteDatabaseFileUsesInjectedURL() async throws {
        let isolatedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "replycant-loader-isolation-\(UUID().uuidString).sqlite"
            )
        defer { try? FileManager.default.removeItem(at: isolatedURL) }

        let defaultURL = ManifestDatabase.defaultDatabaseURL()
        let createdDefaultSentinel = !FileManager.default.fileExists(
            atPath: defaultURL.path
        )
        if createdDefaultSentinel {
            try Data().write(to: defaultURL)
        }
        defer {
            if createdDefaultSentinel {
                try? FileManager.default.removeItem(at: defaultURL)
            }
        }

        let loader = ManifestLoaderManager(
            notificationCenter: NotificationCenter(),
            databaseURL: isolatedURL
        )
        _ = try loader.getDatabase()
        #expect(FileManager.default.fileExists(atPath: isolatedURL.path))

        try await loader.deleteDatabaseFile()

        #expect(!FileManager.default.fileExists(atPath: isolatedURL.path))
        #expect(FileManager.default.fileExists(atPath: defaultURL.path))
    }

    // Deleting the backing file is the destructive half of a reset, and is what
    // UITest fixture seeding uses before rebuilding the cache from HEAD.
    @Test func deleteDatabaseFileBroadcastsInvalidation() async throws {
        let count = try await countInvalidations { loader in
            try await loader.deleteDatabaseFile()
        }

        #expect(count == 1)
    }

    // The timeline must not keep reporting rows from a database that no longer
    // exists, since the grid would render placeholders for unreachable items.
    @Test func timelineClearsStaleCountAfterInvalidation() async throws {
        let center = NotificationCenter()
        let manager = TimelineManager(notificationCenter: center)
        manager.applyDatabaseChange(.fullReplace, refreshedTotalCount: 7)
        #expect(manager.totalCount == 7)

        center.post(
            name: ManifestLoaderManager.databaseDidInvalidateNotification,
            object: nil
        )

        // Delivery hops through the main queue before the manager rebinds, so
        // poll against a wall-clock budget instead of asserting inline.
        let deadline = Date().addingTimeInterval(5)
        while manager.totalCount != 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(manager.totalCount == 0)
    }
}
