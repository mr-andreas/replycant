import Foundation
import Testing
@testable import iosapp

// Covers the retry budget the timeline uses after a database reset.
//
// The reload that follows a reset races the rebuild that replaces the database,
// so it has to tolerate a few transient failures without retrying forever: too
// few attempts leaves the timeline on an error screen, unbounded attempts hide
// a database that is genuinely unusable.
@MainActor
struct RetryBudgetTests {
    // A healthy load must not pay for the retry machinery.
    @Test func stopsAfterFirstSuccess() async {
        var observed = 0

        let attempts = await RetryBudget.run(attempts: 5, delayNanoseconds: 0) {
            observed += 1
            return true
        }

        #expect(attempts == 1)
        #expect(observed == 1)
    }

    // A failure that clears partway through must not consume the whole budget.
    @Test func stopsOnceTheOperationRecovers() async {
        var observed = 0

        let attempts = await RetryBudget.run(attempts: 5, delayNanoseconds: 0) {
            observed += 1
            return observed == 3
        }

        #expect(attempts == 3)
    }

    // A persistently broken database has to surface rather than retry forever.
    @Test func givesUpAfterExhaustingAttempts() async {
        var observed = 0

        let attempts = await RetryBudget.run(attempts: 4, delayNanoseconds: 0) {
            observed += 1
            return false
        }

        #expect(attempts == 4)
        #expect(observed == 4)
    }
}
