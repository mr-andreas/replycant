import Foundation
import Testing
@testable import iosapp

// Verifies periodic sync settings persist correctly and notify runtime managers on changes.
@MainActor
struct SyncSettingsManagerTests {
    // Clears sync-specific defaults so each test starts from known baseline behavior.
    private func clearSyncSettings() {
        UserDefaults.standard.removeObject(forKey: "syncPushEnabled")
        UserDefaults.standard.removeObject(forKey: "syncPullEnabled")
        UserDefaults.standard.removeObject(forKey: "syncPushIntervalSeconds")
        UserDefaults.standard.removeObject(forKey: "syncPullIntervalSeconds")
    }

    // Confirms default settings match product requirements when no values are stored.
    @Test func defaultsAreEnabledAtTwoSeconds() {
        clearSyncSettings()
        let manager = SyncSettingsManager.shared
        #expect(manager.isPushEnabled)
        #expect(manager.isPullEnabled)
        #expect(manager.pushIntervalSeconds == 2.0)
        #expect(manager.pullIntervalSeconds == 2.0)
    }

    // Confirms explicit values are persisted for both directions independently.
    @Test func valuesPersistAcrossReads() {
        clearSyncSettings()
        let manager = SyncSettingsManager.shared
        manager.isPushEnabled = false
        manager.isPullEnabled = true
        manager.pushIntervalSeconds = 5
        manager.pullIntervalSeconds = 7

        #expect(manager.isPushEnabled == false)
        #expect(manager.isPullEnabled == true)
        #expect(manager.pushIntervalSeconds == 5)
        #expect(manager.pullIntervalSeconds == 7)
    }

    // Confirms invalid interval values are clamped to minimum supported cadence.
    @Test func intervalValuesClampToOneSecond() {
        clearSyncSettings()
        let manager = SyncSettingsManager.shared
        manager.pushIntervalSeconds = 0
        manager.pullIntervalSeconds = -5

        #expect(manager.pushIntervalSeconds == 1.0)
        #expect(manager.pullIntervalSeconds == 1.0)
    }

    // Confirms settings mutations emit notifications so long-running services can reconfigure.
    @Test func settingMutationPostsNotification() async {
        clearSyncSettings()
        let manager = SyncSettingsManager.shared

        let stream = NotificationCenter.default.notifications(named: .syncSettingsDidChange)
        let waiter = Task {
            for await _ in stream {
                return true
            }
            return false
        }

        manager.isPushEnabled = false
        let didReceive = await waiter.value
        #expect(didReceive)
    }
}
