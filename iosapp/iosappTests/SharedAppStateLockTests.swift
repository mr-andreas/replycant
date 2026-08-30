import Foundation
import Testing

// Records overlapping critical-section entries so the exclusion lock can
// be proven, not just assumed, before suites share Keychain or sqlite.
actor OverlapProbe {
    private var depth = 0
    private(set) var maxDepth = 0

    // Marks the start of a scoped section so concurrent holders raise depth.
    func enter() {
        depth += 1
        maxDepth = max(maxDepth, depth)
    }

    // Marks the end of a scoped section so depth returns to the prior holder.
    func leave() {
        depth -= 1
    }
}

// Lets the first holder announce it is inside the lock so the second
// caller can attempt entry while the first is still running.
actor OneShot {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signalled = false

    // Wakes the waiter, or records that the signal arrived first.
    func signal() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            signalled = true
        }
    }

    // Suspends until signal() has been called at least once.
    func wait() async {
        if signalled {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

// Guards the cross-suite exclusion lock against a no-op implementation that
// would let Keychain and sqlite mutations interleave again.
struct SharedAppStateLockTests {
    @Test func concurrentScopesDoNotOverlap() async throws {
        let lock = SharedAppStateLock()
        let overlap = OverlapProbe()
        let firstEntered = OneShot()

        async let first: Void = lock.withLock {
            await overlap.enter()
            await firstEntered.signal()
            try await Task.sleep(nanoseconds: 50_000_000)
            await overlap.leave()
        }
        await firstEntered.wait()
        try await lock.withLock {
            await overlap.enter()
            await overlap.leave()
        }
        _ = try await first
        #expect(await overlap.maxDepth == 1)
    }
}
