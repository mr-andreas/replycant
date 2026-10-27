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

    // A launch that iOS rejects has to stay visible, and a second call
    // must not register again. The next process is what retries.
    @Test("Registration records whether this launch was accepted")
    func testRegisterRecordsResult() {
        let rejected = FakeBackgroundTaskScheduler()
        rejected.registerResult = false
        let rejectedScheduler = makeScheduler(tasks: rejected).scheduler
        rejectedScheduler.register()
        rejectedScheduler.register()

        #expect(rejectedScheduler.isRegistered == false)
        #expect(rejected.registerCount == 1)

        let accepted = FakeBackgroundTaskScheduler()
        let acceptedScheduler = makeScheduler(tasks: accepted).scheduler
        acceptedScheduler.register()

        #expect(acceptedScheduler.isRegistered == true)
        #expect(accepted.registerCount == 1)
    }

    // The settings page can only explain a missed night when the last
    // submit's success or error is still there after relaunch.
    @Test("Scheduling stores the time, and a failure stores the error instead")
    func testScheduleResultIsPersisted() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tasks = FakeBackgroundTaskScheduler()
        let (scheduler, defaults) = makeScheduler(tasks: tasks, now: now)

        await scheduler.setEnabled(true)

        #expect(scheduler.lastScheduledAt == now)
        #expect(scheduler.lastScheduleError == nil)
        let reloaded = reload(defaults: defaults, tasks: tasks, now: now)
        #expect(reloaded.lastScheduledAt == now)
        #expect(reloaded.lastScheduleError == nil)

        tasks.submitError = NSError(
            domain: "BackgroundUpload",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Too many pending tasks"]
        )
        scheduler.schedule()

        #expect(scheduler.lastScheduledAt == nil)
        #expect(scheduler.lastScheduleError == "Too many pending tasks")
        let afterFailure = reload(defaults: defaults, tasks: tasks, now: now)
        #expect(afterFailure.lastScheduledAt == nil)
        #expect(afterFailure.lastScheduleError == "Too many pending tasks")
    }

    // Each charging window stays on the list, including one the system
    // killed before it could record how the run ended.
    @Test("A background run is stored and a later finish fills its counts")
    func testRunHistoryPersistsAcrossRelaunch() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let stop = Date(timeIntervalSince1970: 1_800_000_180)
        let (scheduler, defaults) = makeScheduler(
            tasks: FakeBackgroundTaskScheduler(),
            now: start
        )

        let id = scheduler.beginRun(at: start)
        #expect(scheduler.runs.count == 1)
        #expect(scheduler.runs[0].id == id)
        #expect(scheduler.runs[0].stoppedAt == nil)
        #expect(scheduler.runs[0].result == .unfinished)
        #expect(scheduler.runs[0].queueCount == nil)

        let tally = UploadRunTally(
            queueCount: 4,
            uploadedCount: 2,
            uploadedBytes: 4096
        )
        scheduler.finishRun(id: id, at: stop, tally: tally, result: .completed)

        let reloaded = reload(
            defaults: defaults,
            tasks: FakeBackgroundTaskScheduler(),
            now: stop
        )
        #expect(reloaded.runs.count == 1)
        #expect(reloaded.runs[0].startedAt == start)
        #expect(reloaded.runs[0].stoppedAt == stop)
        #expect(reloaded.runs[0].uploadedCount == 2)
        #expect(reloaded.runs[0].uploadedBytes == 4096)
        #expect(reloaded.runs[0].queueCount == 4)
        #expect(reloaded.runs[0].result == .completed)
    }

    // The page lists every recent run, but UserDefaults is not a log.
    @Test("Run history keeps the newest twenty")
    func testRunHistoryKeepsNewestTwenty() {
        let scheduler = makeScheduler(tasks: FakeBackgroundTaskScheduler()).scheduler

        for index in 0..<25 {
            scheduler.beginRun(at: Date(timeIntervalSince1970: TimeInterval(index)))
        }

        #expect(scheduler.runs.count == 20)
        #expect(scheduler.runs[0].startedAt == Date(timeIntervalSince1970: 24))
        #expect(scheduler.runs.last?.startedAt == Date(timeIntervalSince1970: 5))
    }

    // The row words are what Settings shows, so a skipped run with no
    // queue must not look like a completed upload of nothing known.
    @Test("Status copy names registration, schedule, files, bytes, queue, and result")
    func testStatusCopy() {
        let scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let registered = BackgroundUploadStatus(
            isEnabled: true,
            isRegistered: true,
            lastScheduledAt: scheduledAt,
            lastScheduleError: nil,
            runs: []
        )
        let registeredRows = BackgroundUploadStatusCopy.summaryRows(for: registered)
        #expect(registeredRows.map(\.title) == ["Registered", "Last scheduled"])
        #expect(registeredRows.map(\.value) == [
            "Yes",
            BackgroundUploadStatusCopy.timeText(scheduledAt)
        ])

        let failed = BackgroundUploadStatus(
            isEnabled: false,
            isRegistered: false,
            lastScheduledAt: nil,
            lastScheduleError: "Too many pending tasks",
            runs: []
        )
        #expect(BackgroundUploadStatusCopy.summaryRows(for: failed).map(\.value) == [
            "No",
            "Too many pending tasks"
        ])

        let neverScheduled = BackgroundUploadStatus(
            isEnabled: false,
            isRegistered: nil,
            lastScheduledAt: nil,
            lastScheduleError: nil,
            runs: []
        )
        #expect(BackgroundUploadStatusCopy.summaryRows(for: neverScheduled).map(\.value) == [
            "No",
            "Not scheduled"
        ])

        let completed = BackgroundUploadRun(
            id: UUID(),
            startedAt: scheduledAt,
            stoppedAt: scheduledAt.addingTimeInterval(180),
            uploadedCount: 1,
            uploadedBytes: 2048,
            queueCount: 1,
            result: .completed
        )
        #expect(BackgroundUploadStatusCopy.runDetail(completed) ==
            "1 file, \(BackgroundUploadStatusCopy.bytesText(2048)), 1 queued, Completed")

        let skipped = BackgroundUploadRun(
            id: UUID(),
            startedAt: scheduledAt,
            stoppedAt: scheduledAt,
            uploadedCount: 0,
            uploadedBytes: 0,
            queueCount: nil,
            result: .skipped
        )
        #expect(BackgroundUploadStatusCopy.runDetail(skipped) ==
            "0 files, 0 bytes, —, Skipped")
        #expect(BackgroundUploadStatusCopy.timeRange(completed).contains("–"))

        let killed = BackgroundUploadRun(
            id: UUID(),
            startedAt: scheduledAt,
            stoppedAt: nil,
            uploadedCount: 0,
            uploadedBytes: 0,
            queueCount: nil,
            result: .unfinished
        )
        #expect(BackgroundUploadStatusCopy.timeRange(killed) ==
            BackgroundUploadStatusCopy.timeText(scheduledAt))
        #expect(BackgroundUploadStatusCopy.timeRange(killed).contains("–") == false)

        #expect(BackgroundUploadStatusCopy.resultLabel(.expired) == "Stopped early")
        #expect(BackgroundUploadStatusCopy.resultLabel(.alreadyUploading) == "Already uploading")
        #expect(BackgroundUploadStatusCopy.resultLabel(.unfinished) == "Did not finish")
        #expect(BackgroundUploadStatusCopy.bytesText(0) == "0 bytes")
        #expect(BackgroundUploadStatusCopy.bytesText(2048) == "2 KB")
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

    // Reads the same defaults a relaunch would, so a stored run is not
    // only visible inside the process that wrote it.
    private func reload(
        defaults: UserDefaults,
        tasks: FakeBackgroundTaskScheduler,
        now: Date
    ) -> BackgroundUploadScheduler {
        let notifications = FakeReminderCenter()
        let backlog = UploadBacklogTracker(defaults: defaults, notifications: notifications)
        return BackgroundUploadScheduler(
            taskScheduler: tasks,
            defaults: defaults,
            backlog: backlog,
            now: { now }
        )
    }
}

// Records task requests so scheduler tests never talk to BGTaskScheduler.
final class FakeBackgroundTaskScheduler: BackgroundTaskScheduling {
    var submitted: [BGTaskRequest] = []
    var cancelled: [String] = []
    var registerResult = true
    var registerCount = 0
    var submitError: Error?

    func submit(_ request: BGTaskRequest) throws {
        if let submitError {
            throw submitError
        }
        submitted.append(request)
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        cancelled.append(identifier)
    }

    func register(
        forTaskWithIdentifier identifier: String,
        using queue: dispatch_queue_t?,
        launchHandler: @escaping (BGTask) -> Void
    ) -> Bool {
        registerCount += 1
        return registerResult
    }
}
