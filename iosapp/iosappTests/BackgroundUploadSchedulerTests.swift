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

    // The first failing gate is what Settings names. Nil is the only
    // answer that lets the wake upload.
    @Test("A background run starts only when upload is on, photos are allowed, and the network is unmetered")
    func testSkipReasonNamesTheFirstFailingGate() {
        #expect(BackgroundUploadScheduler.skipReason(
            isEnabled: false,
            isPhotoAccessGranted: true,
            network: .allow
        ) == .uploadOff)
        #expect(BackgroundUploadScheduler.skipReason(
            isEnabled: true,
            isPhotoAccessGranted: false,
            network: .allow
        ) == .noPhotoAccess)
        #expect(BackgroundUploadScheduler.skipReason(
            isEnabled: true,
            isPhotoAccessGranted: true,
            network: .notOnWiFi
        ) == .notOnWiFi)
        #expect(BackgroundUploadScheduler.skipReason(
            isEnabled: true,
            isPhotoAccessGranted: true,
            network: .lowData
        ) == .lowData)
        #expect(BackgroundUploadScheduler.skipReason(
            isEnabled: true,
            isPhotoAccessGranted: true,
            network: .wiFiNotConnected
        ) == .wiFiNotConnected)
        #expect(BackgroundUploadScheduler.skipReason(
            isEnabled: false,
            isPhotoAccessGranted: false,
            network: .notOnWiFi
        ) == .uploadOff)
        #expect(BackgroundUploadScheduler.skipReason(
            isEnabled: true,
            isPhotoAccessGranted: false,
            network: .lowData
        ) == .noPhotoAccess)
        #expect(BackgroundUploadScheduler.skipReason(
            isEnabled: true,
            isPhotoAccessGranted: true,
            network: .allow
        ) == nil)
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
        #expect(reloaded.runs[0].skipReason == nil)
    }

    // The settings line is the only place a skip is explained. A run
    // iOS stopped is not a skip, so a reason must not ride along.
    @Test("A skip reason is stored with the run and omitted for any other result")
    func testFinishRunStoresSkipReason() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (scheduler, defaults) = makeScheduler(
            tasks: FakeBackgroundTaskScheduler(),
            now: start
        )
        let skippedID = scheduler.beginRun(at: start)
        scheduler.finishRun(
            id: skippedID,
            at: start,
            tally: .empty,
            result: .skipped,
            skipReason: .wiFiNotConnected
        )
        let expiredID = scheduler.beginRun(at: start)
        scheduler.finishRun(
            id: expiredID,
            at: start,
            tally: .empty,
            result: .expired,
            skipReason: .notOnWiFi
        )

        let reloaded = reload(
            defaults: defaults,
            tasks: FakeBackgroundTaskScheduler(),
            now: start
        )
        #expect(reloaded.runs[0].result == .expired)
        #expect(reloaded.runs[0].skipReason == nil)
        #expect(reloaded.runs[1].result == .skipped)
        #expect(reloaded.runs[1].skipReason == .wiFiNotConnected)
        #expect(BackgroundUploadStatusCopy.runDetail(reloaded.runs[1]) ==
            "0 files, 0 bytes, —, Skipped, Wi-Fi not connected")
    }

    // Rows written before a reason was stored have no key. They still
    // load, and the line stays the old "Skipped".
    @Test("A stored run from before skip reasons still loads")
    func testRunWithoutSkipReasonDecodes() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000002","startedAt":625000000,"uploadedCount":0,"uploadedBytes":0,"result":"skipped"}
        """
        let run = try JSONDecoder().decode(
            BackgroundUploadRun.self,
            from: Data(json.utf8)
        )
        #expect(run.result == .skipped)
        #expect(run.skipReason == nil)
        #expect(BackgroundUploadStatusCopy.runDetail(run) ==
            "0 files, 0 bytes, —, Skipped")
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
    // remainder must not look like a completed upload of nothing known.
    @Test("Status copy names registration, schedule, files, bytes, left, and result")
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
            "1 file, \(BackgroundUploadStatusCopy.bytesText(2048)), 1 left, Completed")

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
        #expect(BackgroundUploadStatusCopy.runDetail(
            skippedRun(at: scheduledAt, reason: .uploadOff)
        ) == "0 files, 0 bytes, —, Skipped, Upload is off")
        #expect(BackgroundUploadStatusCopy.runDetail(
            skippedRun(at: scheduledAt, reason: .noPhotoAccess)
        ) == "0 files, 0 bytes, —, Skipped, No photo access")
        #expect(BackgroundUploadStatusCopy.runDetail(
            skippedRun(at: scheduledAt, reason: .notOnWiFi)
        ) == "0 files, 0 bytes, —, Skipped, Not on Wi-Fi")
        #expect(BackgroundUploadStatusCopy.runDetail(
            skippedRun(at: scheduledAt, reason: .lowData)
        ) == "0 files, 0 bytes, —, Skipped, Low Data Mode")
        #expect(BackgroundUploadStatusCopy.runDetail(
            skippedRun(at: scheduledAt, reason: .wiFiNotConnected)
        ) == "0 files, 0 bytes, —, Skipped, Wi-Fi not connected")
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

    // Completing the charging task while the app is open does not suspend
    // the upload the user is watching. Completing it in the background does.
    @Test("An open app leaves a running upload alone, and a background wake takes it over")
    func testChargingWakeOwnership() {
        #expect(BackgroundUploadScheduler.chargingWakeStart(
            isSyncing: true,
            isApplicationActive: true
        ) == .leaveExistingUpload)
        #expect(BackgroundUploadScheduler.chargingWakeStart(
            isSyncing: false,
            isApplicationActive: true
        ) == .uploadInThisTask)
        #expect(BackgroundUploadScheduler.chargingWakeStart(
            isSyncing: true,
            isApplicationActive: false
        ) == .uploadInThisTask)
        #expect(BackgroundUploadScheduler.chargingWakeStart(
            isSyncing: false,
            isApplicationActive: false
        ) == .uploadInThisTask)
    }

    // The foreground join budget is about ten seconds. A charging wake has
    // the rest of the window, so "still connecting" is tried again. iOS
    // expiring the task, or any other join error, ends the wait.
    @Test("A charging wake retries a tailnet that is still connecting")
    func testTailnetJoinWaitRetriesUntilUpOrStopped() async {
        let joining = ScriptedTailnetJoin(script: [.stillConnecting, .joined])
        let joined = await BackgroundUploadScheduler.waitUntilTailnetJoined(
            isExpired: { false },
            attemptJoin: { joining.next() }
        )
        #expect(joined == .joined)
        #expect(joining.count == 2)

        let expiring = ScriptedTailnetJoin(script: [.stillConnecting], expireAfter: 1)
        let expired = await BackgroundUploadScheduler.waitUntilTailnetJoined(
            isExpired: { expiring.expired },
            attemptJoin: { expiring.next() }
        )
        #expect(expired == .expired)
        #expect(expiring.count == 1)

        let alreadyOver = ScriptedTailnetJoin(script: [.joined])
        alreadyOver.expired = true
        let didNotTry = await BackgroundUploadScheduler.waitUntilTailnetJoined(
            isExpired: { alreadyOver.expired },
            attemptJoin: { alreadyOver.next() }
        )
        #expect(didNotTry == .expired)
        #expect(alreadyOver.count == 0)

        let broken = ScriptedTailnetJoin(script: [.failed, .joined])
        let failed = await BackgroundUploadScheduler.waitUntilTailnetJoined(
            isExpired: { false },
            attemptJoin: { broken.next() }
        )
        #expect(failed == .failed)
        #expect(broken.count == 1)
    }

    // The charging window is short. The library has to be current before
    // either side of the parallel work starts, and those two sides have
    // to share the rest of the window rather than take it in turn.
    @Test("A finished upstream update warms the top cache and uploads together")
    func testFinishedUpdateWarmsAndUploadsTogether() async {
        let probe = ChargingWorkProbe()
        let result = await BackgroundUploadScheduler.runChargingLibraryWork(
            isExpired: { false },
            updateUpstream: {
                await probe.record("pull")
                return .finished
            },
            upload: {
                await probe.occupy("upload")
            },
            warmTopCache: {
                await probe.occupy("warm")
            }
        )

        let summary = await probe.summary()
        #expect(result == .refreshedAndUploaded)
        #expect(summary.events.first == "pull")
        let pull = summary.events.firstIndex(of: "pull")!
        let uploadStart = summary.events.firstIndex(of: "upload-start")!
        let warmStart = summary.events.firstIndex(of: "warm-start")!
        #expect(pull < uploadStart)
        #expect(pull < warmStart)
        #expect(summary.maxInProgress == 2)
    }

    // A bad fetch still continues: the phone should upload the library
    // it already has. A refused database and an expired task must not,
    // or the wake would commit into a format it has rejected or keep
    // working after iOS has taken the process back.
    @Test("A refused or expired upstream update does not warm or upload")
    func testRefusedOrExpiredUpdateStartsNoLibraryWork() async {
        let refused = WorkCounter()
        let refusedResult = await BackgroundUploadScheduler.runChargingLibraryWork(
            isExpired: { false },
            updateUpstream: {
                refused.pulls += 1
                return .refused
            },
            upload: { refused.uploads += 1 },
            warmTopCache: { refused.warms += 1 }
        )
        #expect(refusedResult == .notStarted)
        #expect(refused.pulls == 1)
        #expect(refused.uploads == 0)
        #expect(refused.warms == 0)

        let gaveUp = WorkCounter()
        let gaveUpResult = await BackgroundUploadScheduler.runChargingLibraryWork(
            isExpired: { false },
            updateUpstream: {
                gaveUp.pulls += 1
                return .expired
            },
            upload: { gaveUp.uploads += 1 },
            warmTopCache: { gaveUp.warms += 1 }
        )
        #expect(gaveUpResult == .notStarted)
        #expect(gaveUp.pulls == 1)
        #expect(gaveUp.uploads == 0)
        #expect(gaveUp.warms == 0)

        let alreadyOver = WorkCounter()
        let alreadyOverResult = await BackgroundUploadScheduler.runChargingLibraryWork(
            isExpired: { true },
            updateUpstream: {
                alreadyOver.pulls += 1
                return .finished
            },
            upload: { alreadyOver.uploads += 1 },
            warmTopCache: { alreadyOver.warms += 1 }
        )
        #expect(alreadyOverResult == .notStarted)
        #expect(alreadyOver.pulls == 0)
        #expect(alreadyOver.uploads == 0)
        #expect(alreadyOver.warms == 0)

        let expiredDuringPull = WorkCounter()
        let expiredDuringPullResult = await BackgroundUploadScheduler.runChargingLibraryWork(
            isExpired: { expiredDuringPull.pulls > 0 },
            updateUpstream: {
                expiredDuringPull.pulls += 1
                return .finished
            },
            upload: { expiredDuringPull.uploads += 1 },
            warmTopCache: { expiredDuringPull.warms += 1 }
        )
        #expect(expiredDuringPullResult == .notStarted)
        #expect(expiredDuringPull.pulls == 1)
        #expect(expiredDuringPull.uploads == 0)
        #expect(expiredDuringPull.warms == 0)
    }

    // iOS can end the wake while an upload is still moving. The top-cache
    // downloads have to stop with it, or they keep going until the process
    // is suspended mid-transfer.
    @Test("An upstream update that expires during upload cancels top-cache warming")
    func testExpirationDuringUploadCancelsWarming() async {
        let expiry = WorkCounter()
        let probe = ChargingWorkProbe()
        let result = await BackgroundUploadScheduler.runChargingLibraryWork(
            isExpired: { expiry.uploads > 0 },
            updateUpstream: { .finished },
            upload: { expiry.uploads += 1 },
            warmTopCache: {
                await probe.record(Task.isCancelled ? "cancelled" : "started")
                if Task.isCancelled { return }
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    if Task.isCancelled {
                        await probe.record("cancelled")
                        return
                    }
                }
                await probe.record("finished-uncancelled")
            }
        )

        let events = await probe.summary().events
        #expect(result == .refreshedAndUploaded)
        #expect(events.contains("cancelled"))
        #expect(!events.contains("finished-uncancelled"))
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

    private func skippedRun(
        at date: Date,
        reason: BackgroundUploadSkipReason
    ) -> BackgroundUploadRun {
        BackgroundUploadRun(
            id: UUID(),
            startedAt: date,
            stoppedAt: date,
            uploadedCount: 0,
            uploadedBytes: 0,
            queueCount: nil,
            result: .skipped,
            skipReason: reason
        )
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

// Counts how far a scripted charging wake got. The closures run on the
// main actor, so a plain class is enough to share the tallies.
private final class WorkCounter: @unchecked Sendable {
    var pulls = 0
    var uploads = 0
    var warms = 0
}

// Records whether warming and uploading are in progress together.
// Each side holds its slot briefly so a sequential run cannot look
// overlapped just because both eventually ran.
private actor ChargingWorkProbe {
    private(set) var events: [String] = []
    private var inProgress = 0
    private(set) var maxInProgress = 0

    func record(_ name: String) {
        events.append(name)
    }

    func occupy(_ name: String) async {
        events.append("\(name)-start")
        inProgress += 1
        maxInProgress = max(maxInProgress, inProgress)
        try? await Task.sleep(nanoseconds: 150_000_000)
        events.append("\(name)-end")
        inProgress -= 1
    }

    func summary() -> (events: [String], maxInProgress: Int) {
        (events, maxInProgress)
    }
}

// Plays join results back, and can mark the task expired after a try,
// so the wait is tested without a real tailnet or a processing task.
@MainActor
private final class ScriptedTailnetJoin {
    private let script: [TailnetJoinAttempt]
    private let expireAfter: Int?
    private(set) var count = 0
    var expired = false

    init(script: [TailnetJoinAttempt], expireAfter: Int? = nil) {
        self.script = script
        self.expireAfter = expireAfter
    }

    func next() -> TailnetJoinAttempt {
        let attempt = script[min(count, script.count - 1)]
        count += 1
        if let expireAfter, count >= expireAfter {
            expired = true
        }
        return attempt
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
