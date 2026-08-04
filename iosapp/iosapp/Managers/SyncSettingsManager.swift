import Foundation

// Stores periodic git sync preferences so users can tune background network behavior.
final class SyncSettingsManager {
    static let shared = SyncSettingsManager()

    private let pushEnabledKey = "syncPushEnabled"
    private let pullEnabledKey = "syncPullEnabled"
    private let pushIntervalKey = "syncPushIntervalSeconds"
    private let pullIntervalKey = "syncPullIntervalSeconds"

    private init() {}

    // Enables or disables periodic push without affecting pull settings.
    var isPushEnabled: Bool {
        get { UserDefaults.standard.object(forKey: pushEnabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: pushEnabledKey)
            NotificationCenter.default.post(name: .syncSettingsDidChange, object: nil)
        }
    }

    // Enables or disables periodic pull so users can opt out of inbound sync.
    var isPullEnabled: Bool {
        get { UserDefaults.standard.object(forKey: pullEnabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: pullEnabledKey)
            NotificationCenter.default.post(name: .syncSettingsDidChange, object: nil)
        }
    }

    // Sets push cadence in seconds; defaults to 2 seconds when not configured.
    var pushIntervalSeconds: Double {
        get {
            let value = UserDefaults.standard.double(forKey: pushIntervalKey)
            return value > 0 ? value : 2.0
        }
        set {
            let clamped = max(1.0, newValue)
            UserDefaults.standard.set(clamped, forKey: pushIntervalKey)
            NotificationCenter.default.post(name: .syncSettingsDidChange, object: nil)
        }
    }

    // Sets pull cadence in seconds; defaults to 2 seconds when not configured.
    var pullIntervalSeconds: Double {
        get {
            let value = UserDefaults.standard.double(forKey: pullIntervalKey)
            return value > 0 ? value : 2.0
        }
        set {
            let clamped = max(1.0, newValue)
            UserDefaults.standard.set(clamped, forKey: pullIntervalKey)
            NotificationCenter.default.post(name: .syncSettingsDidChange, object: nil)
        }
    }
}

// Broadcasts sync setting mutations so long-running managers can reconfigure immediately.
extension Notification.Name {
    static let syncSettingsDidChange = Notification.Name("syncSettingsDidChange")
}
