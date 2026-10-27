import Testing
@testable import iosapp

// Checks that the stall reminder opens the timeline and that other
// notifications do not change the selected tab.
@Suite("Upload reminder notification", .serialized)
@MainActor
struct AppNotificationDelegateTests {
    @Test("Tapping the reminder opens the timeline")
    func testReminderTapRequestsTimeline() {
        let delegate = AppNotificationDelegate()

        delegate.handleNotificationTap(identifier: UploadBacklogTracker.reminderIdentifier)

        #expect(delegate.requestedTab == 0)
    }

    @Test("Tapping a different notification leaves the tab alone")
    func testOtherNotificationIsIgnored() {
        let delegate = AppNotificationDelegate()

        delegate.handleNotificationTap(identifier: "some-other-notification")

        #expect(delegate.requestedTab == nil)
    }
}
