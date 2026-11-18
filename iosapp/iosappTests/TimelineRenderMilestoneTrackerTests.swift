import Testing
@testable import iosapp

// Upload waits on this signal. A missed or stuck resume would either
// start the library scan too early or leave it idle for the session.
@Suite("Timeline viewport milestones")
@MainActor
struct TimelineRenderMilestoneTrackerTests {
    @Test("The viewport is hydrated only after every visible item resolves")
    func testHydratesWhenEachVisibleItemResolves() {
        let tracker = TimelineRenderMilestoneTracker()
        tracker.trackVisibleItem("older")
        tracker.trackVisibleItem("newer")

        tracker.markVisibleItemResolved(itemId: "older", didRenderImage: true)

        #expect(!tracker.isViewportHydrated)

        // A failed thumbnail still resolves. The scan may start once the
        // grid has finished trying, even if a cell stays empty.
        tracker.markVisibleItemResolved(itemId: "newer", didRenderImage: false)

        #expect(tracker.isViewportHydrated)
    }

    @Test("A waiter that arrives after hydration returns immediately")
    func testWaitReturnsImmediatelyOnceHydrated() async {
        let tracker = TimelineRenderMilestoneTracker()
        tracker.trackVisibleItem("photo")
        tracker.markVisibleItemResolved(itemId: "photo", didRenderImage: true)

        await tracker.waitUntilViewportHydrated()

        #expect(tracker.isViewportHydrated)
    }

    // The upload gate suspends here. Hydration has to resume it, or the
    // scan waits for the timeout even though the photos are on screen.
    @Test(.timeLimit(.minutes(1)))
    func testWaitResumesWhenTheViewportResolves() async {
        let tracker = TimelineRenderMilestoneTracker()
        tracker.trackVisibleItem("photo")
        let waiter = Task {
            await tracker.waitUntilViewportHydrated()
        }

        tracker.markVisibleItemResolved(itemId: "photo", didRenderImage: true)
        await waiter.value

        #expect(tracker.isViewportHydrated)
    }

    // Leaving the timeline cancels the wait. A leaked continuation would
    // hold the launch task open until the test's time limit.
    @Test(.timeLimit(.minutes(1)))
    func testCancelledWaitDoesNotHang() async {
        let tracker = TimelineRenderMilestoneTracker()
        let waiter = Task {
            await tracker.waitUntilViewportHydrated()
        }

        waiter.cancel()
        await waiter.value
    }
}
