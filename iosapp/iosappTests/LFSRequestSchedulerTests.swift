import Foundation
import Testing
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
}
