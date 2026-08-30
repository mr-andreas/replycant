import Testing

// Serializes tests that share Keychain identity or the process-wide
// manifest cache, which @Suite(.serialized) cannot exclude across files.
actor SharedAppStateLock {
    static let shared = SharedAppStateLock()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // Suspends callers instead of blocking a thread so @MainActor
    // tests can wait without wedging the suite.
    func withLock(
        _ operation: @Sendable () async throws -> Void
    ) async throws {
        await acquire()
        do {
            try await operation()
            release()
        } catch {
            release()
            throw error
        }
    }

    // Parks this caller until the previous holder releases.
    private func acquire() async {
        if isLocked {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } else {
            isLocked = true
        }
    }

    // Hands the lock to the next waiter, or marks it free.
    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// Applies SharedAppStateLock around each test case so suites in
// different files cannot interleave mutations of process-global state.
struct SharedAppState: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    // Skips the suite-level scope so a recursive trait does not deadlock
    // against the test cases it wraps.
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else {
            return try await function()
        }
        try await SharedAppStateLock.shared.withLock(function)
    }
}

extension Trait where Self == SharedAppState {
    static var sharedAppState: Self { Self() }
}
