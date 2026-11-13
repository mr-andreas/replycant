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

    // The badge and the upload scan share this wait. Hydration has to
    // beat the timeout, or they sit out the whole fallback after the
    // photos are already on screen.
    @Test(.timeLimit(.minutes(1)))
    func testWaitWithTimeoutReturnsWhenTheViewportResolves() async {
        let tracker = TimelineRenderMilestoneTracker()
        tracker.trackVisibleItem("photo")
        let started = ContinuousClock.now
        let waiter = Task {
            await tracker.waitUntilViewportHydrated(orAfter: .seconds(30))
        }

        tracker.markVisibleItemResolved(itemId: "photo", didRenderImage: true)
        await waiter.value

        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // An empty grid never hydrates. The wait has to end on its own so
    // the settings badge still appears.
    @Test(.timeLimit(.minutes(1)))
    func testWaitWithTimeoutReturnsWhenHydrationNeverComes() async {
        let tracker = TimelineRenderMilestoneTracker()
        tracker.trackVisibleItem("photo")
        let started = ContinuousClock.now

        await tracker.waitUntilViewportHydrated(orAfter: .milliseconds(300))

        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(3))
        #expect(!tracker.isViewportHydrated)
    }

    // A grid that painted before the waiter subscribed must not sit
    // through the timeout.
    @Test(.timeLimit(.minutes(1)))
    func testWaitWithTimeoutReturnsImmediatelyOnceHydrated() async {
        let tracker = TimelineRenderMilestoneTracker()
        tracker.trackVisibleItem("photo")
        tracker.markVisibleItemResolved(itemId: "photo", didRenderImage: true)
        let started = ContinuousClock.now

        await tracker.waitUntilViewportHydrated(orAfter: .seconds(30))

        #expect(ContinuousClock.now - started < .seconds(2))
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
