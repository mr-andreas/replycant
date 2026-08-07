import Foundation

// Repeats an operation until it succeeds or a bounded budget runs out.
//
// Extracted from the timeline's post-reset reload so the budget can be
// exercised on its own. The reload itself resolves app-wide singletons, and
// forcing it to fail in a test would mean unconfiguring shared state that other
// suites read while running in parallel.
@MainActor
enum RetryBudget {
    /// Runs `operation` until it reports success, up to `attempts` times,
    /// pausing between attempts. Returns how many attempts were made so callers
    /// and tests can tell a first-try success from an exhausted budget.
    /// Stops early if the surrounding task is cancelled.
    @discardableResult
    static func run(
        attempts: Int,
        delayNanoseconds: UInt64,
        operation: () async -> Bool
    ) async -> Int {
        var performed = 0
        for index in 0..<attempts {
            if index > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            if Task.isCancelled {
                return performed
            }
            performed += 1
            if await operation() {
                return performed
            }
        }
        return performed
    }
}
