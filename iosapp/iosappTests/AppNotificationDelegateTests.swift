import Testing
@testable import iosapp

// Checks that the stall reminder opens Upload and that other notifications
// do not change the selected tab.
@Suite("Upload reminder notification", .serialized)
@MainActor
struct AppNotificationDelegateTests {
    @Test("Tapping the reminder opens the Upload tab")
    func testReminderTapRequestsUploadTab() {
        let delegate = AppNotificationDelegate()

        delegate.handleNotificationTap(identifier: UploadBacklogTracker.reminderIdentifier)

        #expect(delegate.requestedTab == 2)
    }

    @Test("Tapping a different notification leaves the tab alone")
    func testOtherNotificationIsIgnored() {
        let delegate = AppNotificationDelegate()

        delegate.handleNotificationTap(identifier: "some-other-notification")

        #expect(delegate.requestedTab == nil)
    }
}
