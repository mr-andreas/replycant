import BackgroundTasks
import Foundation

// Submits and cancels the charging upload so tests can record requests
// without BGTaskScheduler, which the simulator refuses.
protocol BackgroundTaskScheduling: AnyObject {
    func submit(_ request: BGTaskRequest) throws
    func cancel(taskRequestWithIdentifier identifier: String)
}

extension BGTaskScheduler: BackgroundTaskScheduling {}

// Asks iOS to upload while the phone is charging and online, then refuses
// the run unless the path is unmetered. The user turns this on from Upload.
@MainActor
final class BackgroundUploadScheduler: ObservableObject {
    static let shared = BackgroundUploadScheduler()
    static let taskIdentifier = "app.ios.replycant.com.background-upload"

    @Published private(set) var isEnabled: Bool

    private static let enabledKey = "backgroundUploadEnabled"
    private let taskScheduler: BackgroundTaskScheduling
    private let defaults: UserDefaults
    private let backlog: UploadBacklogTracking
    private let now: () -> Date
    private var didRegister = false

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
    }

    // Every launch must register the handler before iOS will run it, including
    // launches that only happen because the task fired.
    func register() {
        guard !didRegister else { return }
        didRegister = true
        let registered = BGTaskScheduler.shared.register(
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
        } catch {
            logError(
                "Failed to schedule background upload: \(error.localizedDescription)",
                context: "BackgroundUpload"
            )
        }
    }

    // All three have to hold. A background run cannot ask the user to
    // confirm mobile data or photo access.
    static func shouldRun(
        isEnabled: Bool,
        isPhotoAccessGranted: Bool,
        allowsAutomaticUpload: Bool
    ) -> Bool {
        isEnabled && isPhotoAccessGranted && allowsAutomaticUpload
    }

    // Reschedules first so a run that is killed still has a next one.
    // An upload the user already started is left alone. A long suspend
    // reclaims the tailnet's sockets, so the upload rebuilds the node
    // before it dials.
    private func handle(_ task: BGProcessingTask) async {
        schedule()
        let control = RunControl()
        task.expirationHandler = {
            let started = control.hasStarted
            Task { @MainActor in
                if started {
                    PhotoSyncManager.shared.cancelSync()
                }
                if control.claimFinish() {
                    task.setTaskCompleted(success: false)
                }
            }
        }

        guard !PhotoSyncManager.shared.isSyncing else {
            if control.claimFinish() {
                task.setTaskCompleted(success: true)
            }
            return
        }

        var finishedThisRun = false
        if await passesGate(), !control.isFinished {
            control.markStarted()
            // A still-connecting join keeps running. The upload waits on
            // that same join, so this error is not a reason to skip the run.
            try? await TailnetBootstrap.shared.noteBackgroundWake()
            await PhotoSyncManager.shared.startSync(order: .smallestFirst)
            await PhotoSyncManager.shared.syncTask?.value
            if case .completed = PhotoSyncManager.shared.syncState {
                finishedThisRun = true
            }
            if await PeriodicSyncManager.shared.pushNow() {
                UploadedMediaCache.shared.flushPending()
            }
        }
        if control.claimFinish() {
            task.setTaskCompleted(success: finishedThisRun)
        }
    }

    private func passesGate() async -> Bool {
        let allowsUpload = await NetworkCostMonitor.shared.waitForAutomaticUploadDecision()
        let photoAccess = PhotoLibraryManager().isAuthorized
        return Self.shouldRun(
            isEnabled: isEnabled,
            isPhotoAccessGranted: photoAccess,
            allowsAutomaticUpload: allowsUpload
        )
    }
}

// Makes sure the system is told the task ended exactly once, including
// when the expiration handler and the upload finish race.
private final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didFinish = false

    func markStarted() {
        lock.lock()
        didStart = true
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

    func claimFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didFinish { return false }
        didFinish = true
        return true
    }
}
