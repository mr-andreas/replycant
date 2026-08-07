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

    // Observes invalidation broadcasts for the duration of one action.
    private func countInvalidations(during action: () throws -> Void) rethrows -> Int {
        let counter = InvalidationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: ManifestLoaderManager.databaseDidInvalidateNotification,
            object: nil,
            queue: nil
        ) { _ in
            counter.count += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try action()
        return counter.count
    }

    // Dropping the shared instance must be announced: callers that already hold
    // the old database would otherwise keep using it indefinitely.
    @Test func clearLoaderBroadcastsInvalidation() {
        let count = countInvalidations {
            ManifestLoaderManager.shared.clearLoader()
        }

        #expect(count == 1)
    }

    // Deleting the backing file is the destructive half of a reset, and is what
    // UITest fixture seeding uses before rebuilding the cache from HEAD.
    @Test func deleteDatabaseFileBroadcastsInvalidation() throws {
        let count = try countInvalidations {
            try ManifestLoaderManager.shared.deleteDatabaseFile()
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

    // A reset deletes the database and immediately rebuilds it, so the reload
    // this manager kicks off races that rebuild and SQLite reports the overlap
    // as a transient I/O error. A single attempt would park the timeline on an
    // error screen until the app restarts, which is how a CI-observed
    // "disk I/O error - while executing BEGIN IMMEDIATE TRANSACTION" turned
    // into a permanently blank timeline.
    //
    // Unconfiguring the server makes every attempt fail, which is what makes
    // the retry observable without reaching into the manager.
    @Test func timelineRetriesReloadWhileItKeepsFailing() async throws {
        let serverURLKey = "gitServerURL"
        let originalServerURL = UserDefaults.standard.string(forKey: serverURLKey)
        UserDefaults.standard.removeObject(forKey: serverURLKey)
        defer {
            if let originalServerURL {
                UserDefaults.standard.set(originalServerURL, forKey: serverURLKey)
            }
        }

        let center = NotificationCenter()
        let manager = TimelineManager(notificationCenter: center)

        center.post(
            name: ManifestLoaderManager.databaseDidInvalidateNotification,
            object: nil
        )
        try await waitUntil(timeout: 5) { manager.errorMessage != nil }
        #expect(manager.errorMessage != nil)

        // Clearing the failure lets a later attempt announce itself by setting
        // it again. The retry loop samples the error before this runs, so it
        // cannot mistake the cleared value for a successful load.
        manager.errorMessage = nil
        try await waitUntil(timeout: 10) { manager.errorMessage != nil }
        #expect(manager.errorMessage != nil)
    }

    // Polls a condition against a wall-clock budget, since these managers
    // publish on the main queue after an async hop.
    private func waitUntil(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
