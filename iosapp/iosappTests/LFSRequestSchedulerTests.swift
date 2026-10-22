import Foundation
import Testing
import LibGit2
@testable import iosapp

/// Coordinates explicit blocking in tests so queueing behavior is deterministic.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Holds callers until tests explicitly release the gate.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Unblocks all current and future waiters.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Captures operation start/end events to assert scheduling behavior.
actor SchedulerProbe {
    private(set) var starts: [String] = []
    private var current = 0
    private(set) var peak = 0
    private(set) var dedupExecutions = 0

    /// Records that one scheduled operation has started.
    func markStart(_ id: String) {
        starts.append(id)
        current += 1
        peak = max(peak, current)
    }

    /// Records that one scheduled operation has finished.
    func markEnd() {
        current = max(0, current - 1)
    }

    /// Counts how many times a deduped operation actually executes.
    func markDedupExecution() {
        dedupExecutions += 1
    }
}

/// Verifies LFS scheduler fairness and interactive-priority guarantees.
@Suite("LFS Request Scheduler Tests", .serialized)
struct LFSRequestSchedulerTests {
    /// Ensures the scheduler never exceeds its configured parallel budget.
    @Test func enforcesMaxConcurrentLimit() async throws {
        let scheduler = LFSRequestScheduler(maxConcurrent: 2)
        let probe = SchedulerProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let key = "concurrency-\(index)"
                    _ = try await scheduler.run(
                        priority: .timelinePage,
                        key: key
                    ) {
                        await probe.markStart(key)
                        try await Task.sleep(nanoseconds: 40_000_000)
                        await probe.markEnd()
                        return index
                    }
                }
            }
            try await group.waitForAll()
        }

        let peak = await probe.peak
        #expect(peak == 2)
    }

    /// Ensures high-priority requests jump ahead of lower queued work.
    @Test func favorsHigherPriorityWhenQueueAdvances() async throws {
        let scheduler = LFSRequestScheduler(maxConcurrent: 1)
        let probe = SchedulerProbe()
        let gate = TestGate()

        let first = Task {
            try await scheduler.run(priority: .timelinePage, key: "first") {
                await probe.markStart("first")
                await gate.wait()
                await probe.markEnd()
                return "first"
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        let lowQueued = Task {
            try await scheduler.run(priority: .timelinePage, key: "low") {
                await probe.markStart("low")
                await probe.markEnd()
                return "low"
            }
        }
        let highQueued = Task {
            try await scheduler.run(priority: .fullscreenCurrent, key: "high") {
                await probe.markStart("high")
                await probe.markEnd()
                return "high"
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        await gate.open()

        _ = try await first.value
        _ = try await lowQueued.value
        _ = try await highQueued.value

        let starts = await probe.starts
        #expect(starts.count == 3)
        #expect(starts[0] == "first")
        #expect(starts[1] == "high")
        #expect(starts[2] == "low")
    }

    /// Ensures callers sharing a key reuse one in-flight fetch operation.
    @Test func deduplicatesInFlightRequestsByKey() async throws {
        let scheduler = LFSRequestScheduler(maxConcurrent: 4)
        let probe = SchedulerProbe()

        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await scheduler.run(priority: .timelineViewport, key: "shared") {
                        await probe.markDedupExecution()
                        try await Task.sleep(nanoseconds: 30_000_000)
                        return 7
                    }
                }
            }

            var collected: [Int] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        #expect(values.count == 10)
        #expect(values.allSatisfy { $0 == 7 })
        let executions = await probe.dedupExecutions
        #expect(executions == 1)
    }

    /// Ensures cancelled queued requests are removed and do not block progress.
    @Test func removesCancelledWaiters() async throws {
        let scheduler = LFSRequestScheduler(maxConcurrent: 1)
        let gate = TestGate()

        let first = Task {
            try await scheduler.run(priority: .timelinePage, key: "first") {
                await gate.wait()
                return 1
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        let cancelled = Task {
            try await scheduler.run(priority: .timelinePage, key: "cancelled") {
                return 2
            }
        }

        cancelled.cancel()

        do {
            _ = try await cancelled.value
            Issue.record("Expected cancelled task to throw CancellationError")
        } catch is CancellationError {
            // expected
        }

        await gate.open()
        _ = try await first.value

        let next = try await scheduler.run(priority: .fullscreenCurrent, key: "next") {
            3
        }
        #expect(next == 3)
    }

    // Confirms a free slot reports no queue wait and inflight of one
    // so a solo download can be told from a contended one.
    @Test func recordsImmediateSlotAsZeroWaitAndInflightOne() async throws {
        let scheduler = LFSRequestScheduler(maxConcurrent: 2)

        let ran = try await scheduler.run(priority: .timelinePage, key: "solo") {
            #expect(LFSDownloadLog.queue?.waitMs == 0)
            #expect(LFSDownloadLog.queue?.inflight == 1)
            return true
        }
        #expect(ran)
    }

    // Confirms a queued request keeps the wait clock and reports how
    // many downloads were already running when its slot opened.
    @Test func recordsQueuedWaitAndInflightAtStart() async throws {
        let scheduler = LFSRequestScheduler(maxConcurrent: 1)
        let gate = TestGate()

        let first = Task {
            try await scheduler.run(priority: .timelinePage, key: "first") {
                await gate.wait()
                return 1
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        let queued = Task {
            try await scheduler.run(priority: .fullscreenCurrent, key: "queued") {
                #expect(LFSDownloadLog.queue?.waitMs ?? 0 > 0)
                #expect(LFSDownloadLog.queue?.inflight == 1)
                return 2
            }
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.open()

        _ = try await first.value
        _ = try await queued.value
    }

    /// A cell load is often already cancelled by the time a free slot opens,
    /// because reloadData() drops the loader while it is still waiting on disk.
    /// That caller must not keep the slot, or the next thumbnail waits forever.
    @Test func cancelledCallerWithFreeSlotDoesNotLeakIt() async throws {
        let scheduler = LFSRequestScheduler(maxConcurrent: 1)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scheduler.run(
                priority: .timelinePage,
                key: "cancelled"
            ) {
                1
            }
        }
        try await expectCancellation(cancelled)

        let followUp = try await firstValueWithinOneSecond {
            try await scheduler.run(
                priority: .timelineViewport,
                key: "follow-up"
            ) {
                2
            }
        }
        #expect(followUp == 2)
    }

    /// One leaked slot is survivable while the budget is larger than one.
    /// The upload burst cancelled more loads than the budget, which is what
    /// froze every later download. Repeating the leak past the budget must
    /// still leave a slot for the next caller.
    @Test func repeatedCancelledCallersDoNotExhaustTheBudget() async throws {
        let budget = 2
        let scheduler = LFSRequestScheduler(maxConcurrent: budget)

        for index in 0..<(budget + 1) {
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await scheduler.run(
                    priority: .timelinePage,
                    key: "cancelled-\(index)"
                ) {
                    index
                }
            }
            try await expectCancellation(cancelled)
        }

        let followUp = try await firstValueWithinOneSecond {
            try await scheduler.run(
                priority: .fullscreenCurrent,
                key: "follow-up"
            ) {
                99
            }
        }
        #expect(followUp == 99)
    }
}

/// The slot leak leaves the next caller parked in the queue. A timeout turns
/// that hang into a failure instead of stalling the suite.
private func firstValueWithinOneSecond<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            throw SlotLeakTimeout()
        }
        guard let value = try await group.next() else {
            throw SlotLeakTimeout()
        }
        group.cancelAll()
        return value
    }
}

/// Confirms an already-cancelled caller stops with CancellationError and
/// does not swallow a different failure as if the leak had been avoided.
private func expectCancellation<T: Sendable>(_ task: Task<T, Error>) async throws {
    do {
        _ = try await task.value
        Issue.record("Expected CancellationError from an already-cancelled caller")
    } catch is CancellationError {
    } catch {
        throw error
    }
}

/// Marks a follow-up download that never received a slot.
private struct SlotLeakTimeout: Error {}
