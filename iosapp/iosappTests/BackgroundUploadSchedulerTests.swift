import BackgroundTasks
import Foundation
import Network
import Testing
@testable import iosapp

// Checks that automatic upload is requested only while charging and on a
// network, and that the switch starts and stops the 7-day clock with it.
@Suite("Background upload scheduler", .serialized)
@MainActor
struct BackgroundUploadSchedulerTests {
    @Test("Background upload is off until the user turns it on")
    func testDisabledByDefault() {
        let tasks = FakeBackgroundTaskScheduler()
        let scheduler = makeScheduler(tasks: tasks).scheduler

        #expect(scheduler.isEnabled == false)
        #expect(tasks.submitted.isEmpty)
    }

    @Test("Turning background upload on asks to run while charging and arms the clock")
    func testEnableSubmitsChargingTaskAndArmsClock() async {
        let tasks = FakeBackgroundTaskScheduler()
        let notifications = FakeReminderCenter()
        notifications.status = .authorized
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (scheduler, defaults) = makeScheduler(
            tasks: tasks,
            notifications: notifications,
            now: now
        )

        await scheduler.setEnabled(true)

        #expect(scheduler.isEnabled == true)
        #expect(tasks.submitted.count == 1)
        let request = tasks.submitted[0] as? BGProcessingTaskRequest
        #expect(request?.identifier == BackgroundUploadScheduler.taskIdentifier)
        #expect(request?.requiresExternalPower == true)
        #expect(request?.requiresNetworkConnectivity == true)
        #expect(defaults.object(forKey: UploadBacklogTracker.startedAtDefaultsKey) as? Date == now)
        #expect(notifications.added.count == 1)
    }

    @Test("Turning background upload off cancels the pending run and the reminder")
    func testDisableCancelsTaskAndClearsClock() async {
        let tasks = FakeBackgroundTaskScheduler()
        let notifications = FakeReminderCenter()
        notifications.status = .authorized
        let (scheduler, defaults) = makeScheduler(tasks: tasks, notifications: notifications)

        await scheduler.setEnabled(true)
        await scheduler.setEnabled(false)

        #expect(scheduler.isEnabled == false)
        #expect(tasks.cancelled == [BackgroundUploadScheduler.taskIdentifier])
        #expect(defaults.object(forKey: UploadBacklogTracker.startedAtDefaultsKey) == nil)
        #expect(notifications.removedPending == [UploadBacklogTracker.reminderIdentifier])
    }

    @Test("A background run starts only when upload is on, photos are allowed, and the network is unmetered")
    func testShouldRunRequiresEveryCondition() {
        #expect(BackgroundUploadScheduler.shouldRun(
            isEnabled: false,
            isPhotoAccessGranted: true,
            allowsAutomaticUpload: true
        ) == false)
        #expect(BackgroundUploadScheduler.shouldRun(
            isEnabled: true,
            isPhotoAccessGranted: false,
            allowsAutomaticUpload: true
        ) == false)
        #expect(BackgroundUploadScheduler.shouldRun(
            isEnabled: true,
            isPhotoAccessGranted: true,
            allowsAutomaticUpload: false
        ) == false)
        #expect(BackgroundUploadScheduler.shouldRun(
            isEnabled: true,
            isPhotoAccessGranted: true,
            allowsAutomaticUpload: true
        ) == true)
    }

    @Test("Automatic upload allows Wi-Fi and refuses metered, Low Data, and offline paths")
    func testAutomaticUploadNetworkRule() {
        #expect(NetworkCostMonitor.allowsAutomaticUpload(
            status: .satisfied,
            isExpensive: false,
            isConstrained: false
        ) == true)
        #expect(NetworkCostMonitor.allowsAutomaticUpload(
            status: .satisfied,
            isExpensive: true,
            isConstrained: false
        ) == false)
        #expect(NetworkCostMonitor.allowsAutomaticUpload(
            status: .satisfied,
            isExpensive: false,
            isConstrained: true
        ) == false)
        #expect(NetworkCostMonitor.allowsAutomaticUpload(
            status: .unsatisfied,
            isExpensive: false,
            isConstrained: false
        ) == false)
    }

    private func makeScheduler(
        tasks: FakeBackgroundTaskScheduler,
        notifications: FakeReminderCenter = FakeReminderCenter(),
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> (scheduler: BackgroundUploadScheduler, defaults: UserDefaults) {
        let suite = "background-upload-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let backlog = UploadBacklogTracker(defaults: defaults, notifications: notifications)
        let scheduler = BackgroundUploadScheduler(
            taskScheduler: tasks,
            defaults: defaults,
            backlog: backlog,
            now: { now }
        )
        return (scheduler, defaults)
    }
}

// Records task requests so scheduler tests never talk to BGTaskScheduler.
final class FakeBackgroundTaskScheduler: BackgroundTaskScheduling {
    var submitted: [BGTaskRequest] = []
    var cancelled: [String] = []

    func submit(_ request: BGTaskRequest) throws {
        submitted.append(request)
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        cancelled.append(identifier)
    }
}
