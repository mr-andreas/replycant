import Synchronization
import Testing
@testable import iosapp

// Locks the UI-test launch contract: fixture setup must not finish before
// the caller returns. XCTest drops the launch when that work stays on the
// main thread long enough to miss the background assertion.
struct TestSupportLaunchTests {

    @Test func scheduleRepositoryPreparationReturnsBeforeTheWorkFinishes() async {
        let finished = Mutex(false)

        TestSupport.scheduleRepositoryPreparation {
            try? await Task.sleep(for: .milliseconds(400))
            finished.withLock { $0 = true }
        }

        #expect(finished.withLock { $0 } == false)

        await TestSupport.waitUntilRepositoryPrepared()
        #expect(finished.withLock { $0 })
    }
}
