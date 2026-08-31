import Foundation
import Testing
@testable import iosapp
import LibGit2

// Verifies periodic sync lifecycle and lock behavior for safe background git scheduling.
@MainActor
@Suite(.serialized, .sharedAppState)
struct PeriodicSyncManagerTests {
    // Coordinates lock-acquired timing so mutation-lock tests avoid scheduler races.
    private actor MutationLockAcquireSignal {
        private var isAcquired = false
        private var continuation: CheckedContinuation<Void, Never>?

        // Marks that the holder entered the critical section before competing acquires run.
        func markAcquired() {
            isAcquired = true
            continuation?.resume()
            continuation = nil
        }

        // Waits until the holder confirms lock ownership.
        func waitUntilAcquired() async {
            if isAcquired {
                return
            }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    // Resets sync defaults so singleton manager starts from deterministic configuration.
    private func resetSyncDefaults() {
        UserDefaults.standard.removeObject(forKey: "syncPushEnabled")
        UserDefaults.standard.removeObject(forKey: "syncPullEnabled")
        UserDefaults.standard.removeObject(forKey: "syncPushIntervalSeconds")
        UserDefaults.standard.removeObject(forKey: "syncPullIntervalSeconds")
    }

    // Polls task state so settings-driven reconfiguration checks do not flake on fixed sleeps.
    private func waitUntil(timeoutNanoseconds: UInt64 = 2_000_000_000, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // Ensures manager starts and stops worker loops predictably from tab lifecycle hooks.
    @Test func startAndStopLifecycle() async {
        resetSyncDefaults()
        let settings = SyncSettingsManager.shared
        settings.isPushEnabled = true
        settings.isPullEnabled = true
        settings.pushIntervalSeconds = 30
        settings.pullIntervalSeconds = 30

        let manager = PeriodicSyncManager.shared
        manager.stop()
        manager.start()

        #expect(manager.isRunningForTesting)
        #expect(manager.hasPushTaskForTesting)
        #expect(manager.hasPullTaskForTesting)

        manager.stop()
        #expect(manager.isRunningForTesting == false)
        #expect(manager.hasPushTaskForTesting == false)
        #expect(manager.hasPullTaskForTesting == false)
    }

    // Ensures pull is attempted immediately on startup so initial convergence does not wait for interval delay.
    @Test func pullStartsImmediatelyOnManagerStart() async {
        resetSyncDefaults()
        let settings = SyncSettingsManager.shared
        settings.isPushEnabled = true
        settings.isPullEnabled = true
        settings.pushIntervalSeconds = 30
        settings.pullIntervalSeconds = 30

        let manager = PeriodicSyncManager.shared
        manager.stop()
        let initialPullCount = manager.pullTickInvocationCountForTesting

        manager.start()

        let pullStartedImmediately = await waitUntil(timeoutNanoseconds: 300_000_000) {
            manager.pullTickInvocationCountForTesting > initialPullCount
        }
        #expect(pullStartedImmediately)

        manager.stop()
    }

    // Ensures settings notifications reconfigure active loops without requiring app restart.
    @Test func settingsChangeReconfiguresTasks() async {
        resetSyncDefaults()
        let settings = SyncSettingsManager.shared
        settings.isPushEnabled = true
        settings.isPullEnabled = true
        settings.pushIntervalSeconds = 30
        settings.pullIntervalSeconds = 30

        let manager = PeriodicSyncManager.shared
        manager.stop()
        manager.start()
        #expect(manager.hasPushTaskForTesting)
        #expect(manager.hasPullTaskForTesting)

        settings.isPullEnabled = false
        let pullDisabled = await waitUntil {
            manager.hasPullTaskForTesting == false && manager.hasPushTaskForTesting
        }
        #expect(pullDisabled)
        #expect(manager.hasPushTaskForTesting)
        #expect(manager.hasPullTaskForTesting == false)

        settings.isPushEnabled = false
        let pushDisabled = await waitUntil {
            manager.hasPushTaskForTesting == false && manager.hasPullTaskForTesting == false
        }
        #expect(pushDisabled)
        #expect(manager.hasPushTaskForTesting == false)
        #expect(manager.hasPullTaskForTesting == false)

        manager.stop()
    }

    // Ensures repository-level mutation lock blocks overlapping pull/push ticks and can be reacquired.
    @Test func repositoryMutationLockExcludesConcurrentWriters() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("periodic-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let repository = try Repository.create(at: root, bare: false)
        let acquireSignal = MutationLockAcquireSignal()

        let holdingTask = Task {
            try await repository.withMutationLock {
                await acquireSignal.markAcquired()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await acquireSignal.waitUntilAcquired()

        let secondAcquire = try await repository.tryWithMutationLock { true }
        #expect(secondAcquire == nil)

        try await holdingTask.value

        let thirdAcquire = try await repository.tryWithMutationLock { true }
        #expect(thirdAcquire == true)
    }

    // Ensures periodic push/pull network work does not overlap and can resume after completion.
    @Test func periodicNetworkOperationGuardSkipsOverlap() {
        let manager = PeriodicSyncManager.shared
        manager.stop()

        let firstAcquire = manager.beginNetworkOperationIfIdleForTesting()
        #expect(firstAcquire)

        let secondAcquire = manager.beginNetworkOperationIfIdleForTesting()
        #expect(secondAcquire == false)

        manager.endNetworkOperationForTesting()

        let thirdAcquire = manager.beginNetworkOperationIfIdleForTesting()
        #expect(thirdAcquire)
        manager.endNetworkOperationForTesting()
    }

    // Ensures generic push-success callback wiring can notify external subscribers without sync-manager coupling.
    @Test func pushSuccessCallbackNotifiesSubscriber() {
        let manager = PeriodicSyncManager.shared
        manager.stop()

        var callbackCount = 0
        manager.onPushSuccess = {
            callbackCount += 1
        }

        manager.notifyPushSuccessForTesting()
        #expect(callbackCount == 1)

        manager.onPushSuccess = nil
    }

    // Ensures non-success push paths do not invoke the push-success callback.
    @Test func pushFailurePathDoesNotNotifySubscriber() {
        let manager = PeriodicSyncManager.shared
        manager.stop()

        var callbackCount = 0
        manager.onPushSuccess = {
            callbackCount += 1
        }

        manager.notifyPushFailureForTesting()
        #expect(callbackCount == 0)

        manager.onPushSuccess = nil
    }

    // A version mismatch is permanent, so the loops must stop and
    // stay stopped even if start() is called again from tab lifecycle.
    @Test func databaseVersionErrorStopsLoopsAndRefusesRestart() async {
        resetSyncDefaults()
        DatabaseCompatibilityManager.shared.clear()
        let settings = SyncSettingsManager.shared
        settings.isPushEnabled = true
        settings.isPullEnabled = true
        settings.pushIntervalSeconds = 30
        settings.pullIntervalSeconds = 30

        let manager = PeriodicSyncManager.shared
        manager.resetDatabaseVersionRefusalForTesting()
        manager.stop()
        manager.start()
        #expect(manager.isRunningForTesting)
        #expect(manager.hasPullTaskForTesting)

        manager.handleDatabaseVersionErrorForTesting(.missing)
        #expect(manager.isRunningForTesting == false)
        #expect(manager.hasPushTaskForTesting == false)
        #expect(manager.hasPullTaskForTesting == false)
        let reported = await waitUntil {
            DatabaseCompatibilityManager.shared.incompatibility != nil
        }
        #expect(reported)

        manager.start()
        #expect(manager.isRunningForTesting == false)

        manager.resetDatabaseVersionRefusalForTesting()
        DatabaseCompatibilityManager.shared.clear()
    }
}
