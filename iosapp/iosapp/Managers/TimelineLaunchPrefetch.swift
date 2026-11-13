import Foundation
import GitDB
import Combine

// Runs the timeline's count and month grouping while SwiftUI is still
// building the first frame. The grid applies the snapshot instead of
// starting those queries after the frame. A write that lands after the
// snapshot was started is discarded: applying it would hide that write
// from the timeline, which only subscribes once it is on screen.
@MainActor
final class TimelineLaunchPrefetch {
    static let shared = TimelineLaunchPrefetch()

    struct Snapshot {
        let totalCount: Int
        let monthCounts: [TimelineMonthCount]
    }

    private struct Attempt {
        let database: ManifestDatabase
        let task: Task<Result<Snapshot, Error>, Never>
    }

    // The change publisher delivers on the writer's thread. The flag has
    // to be visible to take() immediately. Hopping to the main queue
    // could land after the snapshot was already applied.
    private final class StaleFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stale = false

        func mark() {
            lock.lock()
            stale = true
            lock.unlock()
        }

        func reset() {
            lock.lock()
            stale = false
            lock.unlock()
        }

        var isStale: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stale
        }
    }

    private var attempt: Attempt?
    private var changes: AnyCancellable?
    private let stale = StaleFlag()

    // Tests build their own prefetch so they do not consume the launch one.
    init() {}

    // Subscribes before the queries start, so a write during the read is
    // not applied as if it had not happened.
    func start(database: ManifestDatabase) {
        guard attempt == nil else { return }
        stale.reset()
        let stale = self.stale
        changes = database.changes.sink { _ in
            stale.mark()
        }
        attempt = Attempt(
            database: database,
            task: Task.detached(priority: .userInitiated) {
                do {
                    let totalCount = try await DefaultManifestManager.countTimelineOriginals(
                        database: database,
                        scope: .all
                    )
                    let monthCounts = try await DefaultManifestManager.loadTimelineMonthCounts(
                        database: database,
                        scope: .all
                    )
                    return .success(Snapshot(totalCount: totalCount, monthCounts: monthCounts))
                } catch {
                    return .failure(error)
                }
            }
        )
    }

    // Hands the snapshot out once. A second caller, a different cache, a
    // failed read, or a write since start all get nil and query again.
    func take(database: ManifestDatabase) async -> Snapshot? {
        guard let attempt else { return nil }
        self.attempt = nil
        guard attempt.database === database else {
            attempt.task.cancel()
            changes = nil
            return nil
        }
        let result = await attempt.task.value
        let isStale = stale.isStale
        changes = nil
        guard !isStale, case .success(let snapshot) = result else { return nil }
        return snapshot
    }
}
