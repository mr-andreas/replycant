import Foundation
import Testing
import UserNotifications
@testable import iosapp

// Checks the 7-day reminder: when it is scheduled, when a declined
// permission skips it, and when a finished upload removes it.
@Suite("Upload backlog tracker", .serialized)
@MainActor
struct UploadBacklogTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    @Test("An authorized user gets one reminder exactly 7 days out")
    func testArmSchedulesOneReminder() async {
        let notifications = FakeReminderCenter()
        notifications.status = .authorized
        let (tracker, _) = makeTracker(notifications: notifications)

        await tracker.arm(now: start)

        #expect(notifications.added.count == 1)
        let request = notifications.added[0]
        #expect(request.identifier == UploadBacklogTracker.reminderIdentifier)
        #expect(request.content.title == "Uploads not finished")
        #expect(request.content.body == "Some photos and videos have not finished uploading for 7 days. Open Replycant and upload them with the app open.")
        let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
        #expect(trigger?.timeInterval == week)
    }

    @Test("Declined or undecided notification permission stores the clock without a reminder")
    func testArmWithoutPermissionDoesNotSchedule() async {
        for status: UNAuthorizationStatus in [.denied, .notDetermined] {
            let notifications = FakeReminderCenter()
            notifications.status = status
            let (tracker, defaults) = makeTracker(notifications: notifications)

            await tracker.arm(now: start)

            #expect(notifications.added.isEmpty)
            #expect(defaults.object(forKey: UploadBacklogTracker.startedAtDefaultsKey) as? Date == start)
        }
    }

    @Test("Allowing notifications later still reminds at the original deadline")
    func testScheduleAfterGrantKeepsOriginalDeadline() async {
        let notifications = FakeReminderCenter()
        notifications.status = .notDetermined
        let (tracker, _) = makeTracker(notifications: notifications)
        await tracker.arm(now: start)

        notifications.status = .authorized
        let oneHourLater = start.addingTimeInterval(60 * 60)
        await tracker.scheduleReminderIfArmed(now: oneHourLater)

        #expect(notifications.added.count == 1)
        let trigger = notifications.added[0].trigger as? UNTimeIntervalNotificationTrigger
        #expect(trigger?.timeInterval == week - 60 * 60)
    }

    @Test("The explanation is shown only before the user has decided")
    func testNotificationPermissionStep() {
        #expect(UploadBacklogTracker.notificationPermissionStep(status: .notDetermined) == .explain)
        #expect(UploadBacklogTracker.notificationPermissionStep(status: .authorized) == .skip)
        #expect(UploadBacklogTracker.notificationPermissionStep(status: .denied) == .skip)
    }

    @Test("Arming again keeps the original date and the original reminder")
    func testSecondArmIsIgnored() async {
        let notifications = FakeReminderCenter()
        notifications.status = .authorized
        let (tracker, defaults) = makeTracker(notifications: notifications)

        await tracker.arm(now: start)
        await tracker.arm(now: start.addingTimeInterval(week))

        #expect(defaults.object(forKey: UploadBacklogTracker.startedAtDefaultsKey) as? Date == start)
        #expect(notifications.added.count == 1)
    }

    @Test("Clearing the clock removes a pending and a delivered reminder")
    func testClearRemovesReminder() async {
        let notifications = FakeReminderCenter()
        notifications.status = .authorized
        let (tracker, defaults) = makeTracker(notifications: notifications)
        await tracker.arm(now: start)

        tracker.clear()

        #expect(defaults.object(forKey: UploadBacklogTracker.startedAtDefaultsKey) == nil)
        #expect(tracker.isOverdue == false)
        #expect(notifications.removedPending == [UploadBacklogTracker.reminderIdentifier])
        #expect(notifications.removedDelivered == [UploadBacklogTracker.reminderIdentifier])
    }

    @Test("The warning appears at 7 days and not before")
    func testIsOverdueBoundary() {
        #expect(UploadBacklogTracker.isOverdue(startedAt: nil, now: start) == false)
        #expect(UploadBacklogTracker.isOverdue(
            startedAt: start,
            now: start.addingTimeInterval(week - 1)
        ) == false)
        #expect(UploadBacklogTracker.isOverdue(
            startedAt: start,
            now: start.addingTimeInterval(week)
        ) == true)
    }

    private func makeTracker(
        notifications: FakeReminderCenter
    ) -> (UploadBacklogTracker, UserDefaults) {
        let suite = "upload-backlog-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (UploadBacklogTracker(defaults: defaults, notifications: notifications), defaults)
    }
}

// Records reminder scheduling so backlog tests never touch the system center.
final class FakeReminderCenter: UploadReminderNotifying {
    var status: UNAuthorizationStatus = .notDetermined
    var added: [UNNotificationRequest] = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }

    func removePending(identifiers: [String]) {
        removedPending.append(contentsOf: identifiers)
    }

    func removeDelivered(identifiers: [String]) {
        removedDelivered.append(contentsOf: identifiers)
    }
}
