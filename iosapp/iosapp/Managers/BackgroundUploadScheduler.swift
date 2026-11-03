import BackgroundTasks
import Foundation
import UIKit

// Submits and cancels the charging upload so tests can record requests
// without BGTaskScheduler, which the simulator refuses.
protocol BackgroundTaskScheduling: AnyObject {
    func submit(_ request: BGTaskRequest) throws
    func cancel(taskRequestWithIdentifier identifier: String)
    func register(
        forTaskWithIdentifier identifier: String,
        using queue: dispatch_queue_t?,
        launchHandler: @escaping (BGTask) -> Void
    ) -> Bool
}

extension BGTaskScheduler: BackgroundTaskScheduling {}

// How the one-shot upstream fetch at the start of a charging wake ended.
// A normal failure is still finished: the wake uploads the local library.
enum UpstreamPullOutcome: Equatable, Sendable {
    case finished
    case refused
    case expired
}

// Whether the wake went on to warm and upload after that fetch.
enum ChargingLibraryWorkResult: Equatable, Sendable {
    case refreshedAndUploaded
    case notStarted
}

// How a charging run ended, so the settings list can say more than
// whether the task was invoked.
enum BackgroundUploadRunResult: String, Codable, Equatable {
    case completed
    case expired
    case alreadyUploading
    case skipped
    case unfinished
}

// Why a charging wake uploaded nothing. Older rows have none, and the
// settings line stays "Skipped" for those.
enum BackgroundUploadSkipReason: String, Codable, Equatable {
    case uploadOff
    case noPhotoAccess
    case notOnWiFi
    case lowData
    case wiFiNotConnected
}

// One invocation of the charging task. Written when iOS starts it and
// filled in when the upload returns, so a kill still leaves a row.
struct BackgroundUploadRun: Equatable, Codable, Identifiable {
    var id: UUID
    var startedAt: Date
    var stoppedAt: Date?
    var uploadedCount: Int
    var uploadedBytes: Int64
    var queueCount: Int?
    var result: BackgroundUploadRunResult
    var skipReason: BackgroundUploadSkipReason? = nil
}

// The settings page's snapshot. A gallery tile can pass a fixed one
// instead of reading whatever this phone has stored.
struct BackgroundUploadStatus: Equatable {
    var isEnabled: Bool
    var isRegistered: Bool?
    var lastScheduledAt: Date?
    var lastScheduleError: String?
    var runs: [BackgroundUploadRun]
}

// A charging wake finds a sync already running. Leaving it alone is only
// safe while the app is open: completing the task otherwise lets iOS
// suspend that sync, and every later wake sees it still running.
enum ChargingWakeStart: Equatable {
    case leaveExistingUpload
    case uploadInThisTask
}

// What one join attempt did. Still connecting is not a failure: the node
// is still coming up, and a charging window can wait for it.
enum TailnetJoinAttempt: Equatable {
    case joined
    case stillConnecting
    case failed
}

// Why a charging wake stopped waiting for the library network.
enum TailnetJoinOutcome: Equatable {
    case joined
    case expired
    case failed
}

// Asks iOS to run while the phone is charging and online, then refuses
// the run unless the path is unmetered. The wake fetches the latest
// library, then uploads and fills the top thumbnail cache. The user
// turns this on from the timeline or from Settings. The same switch
// starts foreground upload.
@MainActor
final class BackgroundUploadScheduler: ObservableObject, UploadEnabling {
    static let shared = BackgroundUploadScheduler()
    static let taskIdentifier = "app.ios.replycant.com.background-upload"

    @Published private(set) var isEnabled: Bool
    // Nil until this process has tried to register. A previous launch's
    // success does not mean this one was accepted.
    @Published private(set) var isRegistered: Bool?
    @Published private(set) var lastScheduledAt: Date?
    @Published private(set) var lastScheduleError: String?
    // Newest first. Capped so a phone that charges every night does not
    // grow this list without bound.
    @Published private(set) var runs: [BackgroundUploadRun] = []

    static let runHistoryLimit = 20
    private static let enabledKey = "backgroundUploadEnabled"
    private static let lastScheduledAtKey = "backgroundUploadLastScheduledAt"
    private static let lastScheduleErrorKey = "backgroundUploadLastScheduleError"
    private static let runsKey = "backgroundUploadRuns"
    private let taskScheduler: BackgroundTaskScheduling
    private let defaults: UserDefaults
    private let backlog: UploadBacklogTracking
    private let now: () -> Date
    private var didRegister = false
    // The expiration handler cancels this between thumbnails. It is
    // nil until the upstream fetch has finished and warming starts.
    private var topCacheWarmTask: Task<Void, Never>?

    init(
        taskScheduler: BackgroundTaskScheduling = BGTaskScheduler.shared,
        defaults: UserDefaults = .standard,
        backlog: UploadBacklogTracking? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.taskScheduler = taskScheduler
        self.defaults = defaults
        self.backlog = backlog ?? UploadBacklogTracker.shared
        self.now = now
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        self.lastScheduledAt = defaults.object(forKey: Self.lastScheduledAtKey) as? Date
        self.lastScheduleError = defaults.string(forKey: Self.lastScheduleErrorKey)
        if let data = defaults.data(forKey: Self.runsKey),
           let stored = try? JSONDecoder().decode([BackgroundUploadRun].self, from: data) {
            self.runs = stored
        }
    }

    // The settings page reads one value so a preview can substitute a
    // fixed history without touching the live scheduler.
    var status: BackgroundUploadStatus {
        BackgroundUploadStatus(
            isEnabled: isEnabled,
            isRegistered: isRegistered,
            lastScheduledAt: lastScheduledAt,
            lastScheduleError: lastScheduleError,
            runs: runs
        )
    }

    // Every launch must register the handler before iOS will run it, including
    // launches that only happen because the task fired.
    func register() {
        guard !didRegister else { return }
        didRegister = true
        let registered = taskScheduler.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await BackgroundUploadScheduler.shared.handle(processingTask)
            }
        }
        isRegistered = registered
        if !registered {
            logError("Background upload task was not registered", context: "BackgroundUpload")
        }
    }

    // Turning this on starts the 7-day clock immediately. The reminder is
    // how the user learns that a charging window never arrived.
    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            schedule()
            await backlog.start(now: now())
        } else {
            taskScheduler.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            backlog.clear()
        }
    }

    // Submits one charging, networked run. iOS chooses the time. Calling
    // this again replaces the pending request.
    func schedule() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        do {
            try taskScheduler.submit(request)
            lastScheduledAt = now()
            lastScheduleError = nil
            defaults.set(lastScheduledAt, forKey: Self.lastScheduledAtKey)
            defaults.removeObject(forKey: Self.lastScheduleErrorKey)
        } catch {
            // The latest attempt is what the settings page shows. An older
            // success would hide the reason nothing is waiting to run.
            lastScheduledAt = nil
            lastScheduleError = error.localizedDescription
            defaults.removeObject(forKey: Self.lastScheduledAtKey)
            defaults.set(lastScheduleError, forKey: Self.lastScheduleErrorKey)
            logError(
                "Failed to schedule background upload: \(error.localizedDescription)",
                context: "BackgroundUpload"
            )
        }
    }

    // Writes a row as soon as iOS launches the task. A kill before the
    // upload finishes still leaves the start time on the settings page.
    func beginRun(at date: Date) -> UUID {
        let run = BackgroundUploadRun(
            id: UUID(),
            startedAt: date,
            stoppedAt: nil,
            uploadedCount: 0,
            uploadedBytes: 0,
            queueCount: nil,
            result: .unfinished
        )
        runs.insert(run, at: 0)
        if runs.count > Self.runHistoryLimit {
            runs.removeLast(runs.count - Self.runHistoryLimit)
        }
        persistRuns()
        return run.id
    }

    // Fills the row opened by beginRun once the upload task has returned,
    // including a run iOS stopped early.
    func finishRun(
        id: UUID,
        at date: Date,
        tally: UploadRunTally,
        result: BackgroundUploadRunResult,
        skipReason: BackgroundUploadSkipReason? = nil
    ) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].stoppedAt = date
        runs[index].uploadedCount = tally.uploadedCount
        runs[index].uploadedBytes = tally.uploadedBytes
        runs[index].queueCount = tally.queueCount
        runs[index].result = result
        // An expired or unfinished run is not a skip. Keeping a reason
        // there would tell the settings page the wrong story.
        runs[index].skipReason = result == .skipped ? skipReason : nil
        persistRuns()
    }

    private func persistRuns() {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: Self.runsKey)
    }

    // The first failing gate is the one Settings names. Nil means this
    // wake may upload. A background run cannot ask the user to confirm
    // mobile data or photo access.
    static func skipReason(
        isEnabled: Bool,
        isPhotoAccessGranted: Bool,
        network: AutomaticUploadDecision
    ) -> BackgroundUploadSkipReason? {
        if !isEnabled {
            return .uploadOff
        }
        if !isPhotoAccessGranted {
            return .noPhotoAccess
        }
        switch network {
        case .allow:
            return nil
        case .notOnWiFi:
            return .notOnWiFi
        case .lowData:
            return .lowData
        case .wiFiNotConnected:
            return .wiFiNotConnected
        }
    }

    // An open upload is the user's. A background wake owns the run even
    // when a path update or a previous suspend left a sync marked active,
    // because completing the task would freeze that sync.
    static func chargingWakeStart(
        isSyncing: Bool,
        isApplicationActive: Bool
    ) -> ChargingWakeStart {
        if isSyncing && isApplicationActive {
            return .leaveExistingUpload
        }
        return .uploadInThisTask
    }

    // Fetches upstream before warming or uploading. Those two share the
    // rest of the window. A refusal or an expired task starts neither:
    // a refused database cannot take new commits, and iOS is about to
    // suspend an expired one. The warm task is cancellable so expiration
    // during the upload stops thumbnail downloads between items.
    static func runChargingLibraryWork(
        isExpired: () -> Bool,
        updateUpstream: () async -> UpstreamPullOutcome,
        upload: () async -> Void,
        warmTopCache: @escaping () async -> Void,
        registerWarmTask: (Task<Void, Never>) -> Void = { _ in }
    ) async -> ChargingLibraryWorkResult {
        if isExpired() {
            return .notStarted
        }
        let update = await updateUpstream()
        guard update == .finished, !isExpired() else {
            return .notStarted
        }
        let warmTask = Task { await warmTopCache() }
        registerWarmTask(warmTask)
        await upload()
        if isExpired() {
            warmTask.cancel()
        }
        await warmTask.value
        return .refreshedAndUploaded
    }

    // Keeps waiting through the foreground join timeout. A charging wake
    // has the rest of the window, and ending on the first still-connecting
    // miss uploads nothing. Any other error, or iOS expiring the task, stops.
    static func waitUntilTailnetJoined(
        isExpired: () -> Bool,
        attemptJoin: () async -> TailnetJoinAttempt
    ) async -> TailnetJoinOutcome {
        while !isExpired() {
            switch await attemptJoin() {
            case .joined:
                return isExpired() ? .expired : .joined
            case .stillConnecting:
                continue
            case .failed:
                return isExpired() ? .expired : .failed
            }
        }
        return .expired
    }

    // Records the run, then reschedules so a kill still has a next one.
    // An upload the user is watching is left alone. Otherwise the wake
    // fetches upstream, then warms the top thumbnail cache while it
    // uploads. A sync left running while the app is not active is
    // cancelled: its sockets are the ones this wake rebuilds, and
    // reporting the task finished would suspend it. The stay starts
    // when the task is finished, because that is when iOS is allowed
    // to suspend the process.
    private func handle(_ task: BGProcessingTask) async {
        let runID = beginRun(at: now())
        schedule()
        let control = RunControl()
        task.expirationHandler = {
            control.markExpired()
            let started = control.hasStarted
            Task { @MainActor in
                if started {
                    PhotoSyncManager.shared.cancelSync()
                    BackgroundUploadScheduler.shared.cancelTopCacheWarm()
                }
                // iOS can suspend as soon as the task is completed, which
                // may be before this function reaches its own finish.
                await BackgroundUploadScheduler.shared.recordBackgroundStay()
                if control.claimFinish() {
                    task.setTaskCompleted(success: false)
                }
            }
        }

        let wake = Self.chargingWakeStart(
            isSyncing: PhotoSyncManager.shared.isSyncing,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        if wake == .leaveExistingUpload {
            await recordBackgroundStay()
            if control.claimFinish() {
                task.setTaskCompleted(success: true)
            }
            finishRun(
                id: runID,
                at: now(),
                tally: .empty,
                result: .alreadyUploading
            )
            return
        }
        if PhotoSyncManager.shared.isSyncing {
            PhotoSyncManager.shared.cancelSync()
        }

        var result: BackgroundUploadRunResult = .skipped
        var skipReason: BackgroundUploadSkipReason?
        var tally = UploadRunTally.empty
        let gate = await passesGate()
        if gate == nil, !control.isFinished {
            control.markStarted()
            if await libraryNetworkIsReady(control), !control.isFinished {
                let work = await Self.runChargingLibraryWork(
                    isExpired: { control.wasExpired || control.isFinished },
                    updateUpstream: {
                        await PeriodicSyncManager.shared.pullNow(
                            isExpired: { control.wasExpired || control.isFinished }
                        )
                    },
                    upload: {
                        await PhotoSyncManager.shared.startSync(order: .smallestFirst)
                        await PhotoSyncManager.shared.syncTask?.value
                        tally = PhotoSyncManager.shared.runTally
                        if control.wasExpired {
                            result = .expired
                        } else if case .completed = PhotoSyncManager.shared.syncState {
                            result = .completed
                        } else {
                            result = .unfinished
                        }
                        if await PeriodicSyncManager.shared.pushNow() {
                            UploadedMediaCache.shared.flushPending()
                        }
                    },
                    warmTopCache: {
                        await DiskCacheWarming.warmTopCacheFromLibrary()
                    },
                    registerWarmTask: { warmTask in
                        self.topCacheWarmTask = warmTask
                    }
                )
                topCacheWarmTask = nil
                if work == .notStarted {
                    result = control.wasExpired ? .expired : .unfinished
                }
            } else if control.wasExpired {
                result = .expired
            } else {
                result = .unfinished
            }
        } else if control.wasExpired {
            result = .expired
        } else {
            skipReason = gate
        }
        await recordBackgroundStay()
        if control.claimFinish() {
            task.setTaskCompleted(success: result == .completed)
        }
        finishRun(
            id: runID,
            at: now(),
            tally: tally,
            result: result,
            skipReason: skipReason
        )
    }

    // Rebuilds after a long suspend, then waits out "still connecting".
    // The foreground timeout is what used to end the run while the node
    // was still coming up. A different join error ends the wake.
    private func libraryNetworkIsReady(_ control: RunControl) async -> Bool {
        do {
            try await TailnetBootstrap.shared.noteBackgroundWake()
        } catch TailnetBootstrap.BootstrapError.stillConnecting {
            // The rebuild keeps running. The wait below uses that same join.
        } catch {
            logError(
                "Background upload could not rebuild the tailnet: \(error.localizedDescription)",
                context: "BackgroundUpload"
            )
            return false
        }
        let outcome = await Self.waitUntilTailnetJoined(
            isExpired: { control.wasExpired || control.isFinished },
            attemptJoin: { await self.attemptTailnetJoin() }
        )
        return outcome == .joined
    }

    // One slice of the join wait. Still connecting is retried by the caller.
    private func attemptTailnetJoin() async -> TailnetJoinAttempt {
        do {
            try await TailnetBootstrap.shared.ensureJoinedIfConfigured()
            return .joined
        } catch TailnetBootstrap.BootstrapError.stillConnecting {
            return .stillConnecting
        } catch {
            logError(
                "Background upload could not join the tailnet: \(error.localizedDescription)",
                context: "BackgroundUpload"
            )
            return .failed
        }
    }

    // Stops thumbnail downloads between items when iOS expires the wake.
    // The in-flight download can finish; the next one does not start.
    private func cancelTopCacheWarm() {
        topCacheWarmTask?.cancel()
    }

    // The node's sockets survive only while this process does. iOS may
    // suspend it the moment the charging task is reported finished, so
    // the stay has to be on record before that call. Recording it again
    // only moves the time forward.
    private func recordBackgroundStay() async {
        await TailnetBootstrap.shared.noteBackgroundRunEnded(
            isAppActive: UIApplication.shared.applicationState == .active
        )
    }

    private func passesGate() async -> BackgroundUploadSkipReason? {
        let network = await NetworkCostMonitor.shared.waitForAutomaticUploadDecision()
        return Self.skipReason(
            isEnabled: isEnabled,
            isPhotoAccessGranted: PhotoLibraryManager().isAuthorized,
            network: network
        )
    }
}

// Makes sure the system is told the task ended exactly once, including
// when the expiration handler and the upload finish race.
private final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didFinish = false
    private var didExpire = false

    func markStarted() {
        lock.lock()
        didStart = true
        lock.unlock()
    }

    // The expiration handler and the upload can finish on different
    // queues. The history row uses this so a stopped run is not recorded
    // as completed just because files had already landed.
    func markExpired() {
        lock.lock()
        didExpire = true
        lock.unlock()
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish
    }

    var wasExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExpire
    }

    func claimFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didFinish { return false }
        didFinish = true
        return true
    }
}
