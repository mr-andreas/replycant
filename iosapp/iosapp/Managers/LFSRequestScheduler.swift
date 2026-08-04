import Foundation

/// Encodes LFS fetch urgency so interactive media can run before warmup.
enum ImageLoadPriority: Int, Comparable, Sendable {
    case mainWarm = 0
    case topWarm = 1
    case timelinePage = 2
    case timelineViewport = 3
    case fullscreenNeighbor = 4
    case fullscreenCurrent = 5

    /// Keeps the scheduler ordering explicit and testable.
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Limits concurrent LFS fetches and serves queued work by priority.
actor LFSRequestScheduler {
    /// Captures one suspended caller waiting for a download slot.
    private struct Waiter {
        let id: UInt64
        let sequence: UInt64
        let priority: ImageLoadPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Tracks one in-flight keyed request so concurrent callers can share it.
    private struct SharedRequest {
        let typeID: ObjectIdentifier
        let task: Task<any Sendable, Error>
    }

    /// Surfaces invalid keyed re-use where callers expect different result
    /// types for the same key.
    enum SchedulerError: Error {
        case keyTypeMismatch
    }

    private let maxConcurrent: Int
    private var runningCount = 0
    private var nextWaiterID: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var waitersByID: [UInt64: Waiter] = [:]
    private var inFlightByKey: [String: SharedRequest] = [:]

    /// Creates a scheduler with a fixed concurrency budget.
    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Runs an operation when a slot is available and shares keyed in-flight
    /// work with other callers.
    func run<T: Sendable>(
        priority: ImageLoadPriority,
        key: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if let shared = inFlightByKey[key] {
            return try await awaitShared(shared)
        }

        try await acquirePermit(priority: priority)
        try Task.checkCancellation()

        let shared = SharedRequest(
            typeID: ObjectIdentifier(T.self),
            task: Task.detached {
                try await operation() as any Sendable
            }
        )
        inFlightByKey[key] = shared

        defer {
            inFlightByKey.removeValue(forKey: key)
            releasePermit()
        }

        return try await awaitShared(shared)
    }

    /// Waits for an in-flight keyed operation and enforces result type safety.
    private func awaitShared<T: Sendable>(_ shared: SharedRequest) async throws -> T {
        let requestedType = ObjectIdentifier(T.self)
        guard shared.typeID == requestedType else {
            throw SchedulerError.keyTypeMismatch
        }

        let value = try await shared.task.value
        guard let typed = value as? T else {
            throw SchedulerError.keyTypeMismatch
        }
        return typed
    }

    /// Reserves a running slot immediately or queues this caller by priority.
    private func acquirePermit(priority: ImageLoadPriority) async throws {
        if runningCount < maxConcurrent {
            runningCount += 1
            return
        }

        let waiterID = nextWaiterID
        nextWaiterID += 1
        let sequence = nextSequence
        nextSequence += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(
                    id: waiterID,
                    sequence: sequence,
                    priority: priority,
                    continuation: continuation
                )
                waitersByID[waiterID] = waiter
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    /// Drops a cancelled waiter so it does not consume queue capacity.
    private func cancelWaiter(id: UInt64) {
        guard let waiter = waitersByID.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Releases one slot or hands it to the best queued waiter.
    private func releasePermit() {
        guard let waiter = nextWaiter() else {
            runningCount = max(0, runningCount - 1)
            return
        }
        waitersByID.removeValue(forKey: waiter.id)
        waiter.continuation.resume()
    }

    /// Picks the highest-priority waiter, preserving FIFO inside a priority.
    private func nextWaiter() -> Waiter? {
        waitersByID.values.max { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.sequence > rhs.sequence
            }
            return lhs.priority < rhs.priority
        }
    }
}
