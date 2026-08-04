import Foundation
import LibGit2

// Runs periodic push/pull so devices converge automatically without manual sync actions.
final class PeriodicSyncManager {
    static let shared = PeriodicSyncManager()

    private let stateLock = NSLock()
    private let operationStateLock = NSLock()
    private var pushSuccessHandler: (@Sendable () -> Void)?
    private var isRunning = false
    private var isNetworkOperationInProgress = false
    private var pushTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?
#if DEBUG
    private var pullTickInvocationCount = 0
#endif

    private init() {}

    // Publishes successful push ticks to subscribers that need post-push side effects.
    var onPushSuccess: (@Sendable () -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return pushSuccessHandler
        }
        set {
            stateLock.lock()
            pushSuccessHandler = newValue
            stateLock.unlock()
        }
    }

    // Starts periodic sync loops and settings observation once repository flows are active.
    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return }
        isRunning = true
        registerSettingsObserverLocked()
        reconfigureTasksLocked()
        log("Started periodic sync manager", context: "Sync")
    }

    // Stops periodic sync loops so destructive flows can safely reset local state.
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return }
        isRunning = false
        pushTask?.cancel()
        pullTask?.cancel()
        pushTask = nil
        pullTask = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        log("Stopped periodic sync manager", context: "Sync")
    }

    // Rebuilds push/pull loops after settings changes so new intervals apply immediately.
    private func handleSettingsChange() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return }
        reconfigureTasksLocked()
        log("Reconfigured periodic sync loops from settings", context: "Sync")
    }

    // Creates one NotificationCenter observer to react to sync settings mutations.
    private func registerSettingsObserverLocked() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .syncSettingsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleSettingsChange()
        }
    }

    // Applies current settings by replacing running tasks with fresh loops.
    private func reconfigureTasksLocked() {
        pushTask?.cancel()
        pullTask?.cancel()
        pushTask = nil
        pullTask = nil

        let settings = SyncSettingsManager.shared
        if settings.isPushEnabled {
            pushTask = Task { [weak self] in
                await self?.runPushLoop()
            }
        }
        if settings.isPullEnabled {
            pullTask = Task { [weak self] in
                await self?.runPullLoop()
            }
        }
    }

    // Executes push ticks at the configured cadence until the task is cancelled.
    private func runPushLoop() async {
        while !Task.isCancelled {
            let intervalSeconds = SyncSettingsManager.shared.pushIntervalSeconds
            try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await performPushTick()
        }
    }

    // Executes pull ticks at the configured cadence until the task is cancelled.
    private func runPullLoop() async {
        guard !Task.isCancelled else { return }
        recordPullTickInvocationForTesting()
        await performPullTick()

        while !Task.isCancelled {
            let intervalSeconds = SyncSettingsManager.shared.pullIntervalSeconds
            try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            recordPullTickInvocationForTesting()
            await performPullTick()
        }
    }

    // Pushes local commits to origin and logs operation duration for performance visibility.
    private func performPushTick() async {
        guard beginNetworkOperationIfIdle() else {
            logDebug("Skipping periodic push because another periodic network operation is running", context: "Sync")
            return
        }
        defer { endNetworkOperation() }

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            try ensureMTLSTransportConfigured()
            let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
            let pushed = try await repository.tryWithMutationLock {
                let branchName = repository.currentBranch() ?? "main"
                try repository.push(remoteName: "origin", branchName: branchName)
                return true
            }
            guard pushed != nil else {
                logDebug("Skipping periodic push because another mutating git operation is running", context: "Sync")
                return
            }
            notifyPushSuccess()
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            logDebug("Periodic push completed in \(String(format: "%.3f", duration)) seconds", context: "Sync")
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            logError("Periodic push failed after \(String(format: "%.3f", duration)) seconds: \(error.localizedDescription)", context: "Sync")
        }
    }

    // Pulls remote changes and refreshes SQL manifest cache so pubsub updates timeline readers.
    private func performPullTick() async {
        guard beginNetworkOperationIfIdle() else {
            logDebug("Skipping periodic pull because another periodic network operation is running", context: "Sync")
            return
        }
        defer { endNetworkOperation() }

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            try ensureMTLSTransportConfigured()
            let repository = try await MainActor.run { try RepositoryManager.shared.getRepository() }
            let gitDB = try await MainActor.run { try GitDBManager.shared.getGitDB() }
            let pulled = try await repository.tryWithMutationLock {
                let branchName = repository.currentBranch() ?? "main"
                try repository.pullRebase(remoteName: "origin", branchName: branchName, progressCallback: nil)
                try await gitDB.syncToHead(progressHandler: nil)
                return true
            }
            guard pulled != nil else {
                logDebug("Skipping periodic pull because another mutating git operation is running", context: "Sync")
                return
            }

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            logDebug("Periodic pull completed in \(String(format: "%.3f", duration)) seconds", context: "Sync")
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            logError("Periodic pull failed after \(String(format: "%.3f", duration)) seconds: \(error.localizedDescription)", context: "Sync")
        }
    }

    // Ensures mTLS transport is configured before any network git operation executes.
    private func ensureMTLSTransportConfigured() throws {
        guard let identity = ClientIdentityManager.shared.loadSecIdentity(),
              let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw MTLSTransportError.notConfigured
        }
        try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)
    }

    // Reserves the periodic network slot so push and pull never run concurrently.
    private func beginNetworkOperationIfIdle() -> Bool {
        operationStateLock.lock()
        defer { operationStateLock.unlock() }
        if isNetworkOperationInProgress {
            return false
        }
        isNetworkOperationInProgress = true
        return true
    }

    // Releases the periodic network slot after one push or pull tick completes.
    private func endNetworkOperation() {
        operationStateLock.lock()
        isNetworkOperationInProgress = false
        operationStateLock.unlock()
    }

    // Notifies subscribers only after a push succeeds so downstream state reflects server-confirmed commits.
    private func notifyPushSuccess() {
        let handler: (@Sendable () -> Void)?
        stateLock.lock()
        handler = pushSuccessHandler
        stateLock.unlock()
        handler?()
    }

    // Records pull-loop ticks so tests can confirm pull starts immediately when sync starts.
    private func recordPullTickInvocationForTesting() {
#if DEBUG
        stateLock.lock()
        pullTickInvocationCount += 1
        stateLock.unlock()
#endif
    }
}

#if DEBUG
// Exposes non-production state for deterministic unit tests around lifecycle and reconfiguration behavior.
extension PeriodicSyncManager {
    // Exposes running state for unit tests validating lifecycle control.
    var isRunningForTesting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    // Exposes push-loop availability for unit tests validating settings reconfiguration.
    var hasPushTaskForTesting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pushTask != nil
    }

    // Exposes pull-loop availability for unit tests validating settings reconfiguration.
    var hasPullTaskForTesting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pullTask != nil
    }

    // Allows tests to assert push/pull overlap prevention logic without running network requests.
    func beginNetworkOperationIfIdleForTesting() -> Bool {
        beginNetworkOperationIfIdle()
    }

    // Allows tests to release the overlap guard after synthetic acquisition.
    func endNetworkOperationForTesting() {
        endNetworkOperation()
    }

    // Exposes pull-loop tick count so tests can verify first pull is attempted immediately.
    var pullTickInvocationCountForTesting: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pullTickInvocationCount
    }

    // Triggers the same callback path as a successful push so tests can assert subscriber wiring.
    func notifyPushSuccessForTesting() {
        notifyPushSuccess()
    }

    // Leaves callbacks untouched to model failed pushes that should not notify subscribers.
    func notifyPushFailureForTesting() {}
}
#endif
