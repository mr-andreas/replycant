import Foundation
import Testing
@testable import iosapp

// Verifies the UITest hydration gate wakes waiters only after fixture sync
// completes, so timeline startup cannot bind to a DB that setup still replaces.
struct TestSupportHydrationGateTests {
    @Test @MainActor
    func waitForFixtureHydrationReturnsAfterCompletionSignal() async {
        TestSupport.resetFixtureHydrationGateForTesting()

        let waiter = Task {
            await TestSupport.waitForFixtureHydration()
        }

        // Yield so the waiter parks on the gate before completion is signaled.
        await Task.yield()
        #expect(waiter.isCancelled == false)

        TestSupport.noteFixtureHydrationCompleteForTesting()
        await waiter.value

        // A second wait after completion must not block.
        await TestSupport.waitForFixtureHydration()
    }
}
