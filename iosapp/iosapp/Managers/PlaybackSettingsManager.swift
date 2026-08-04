import Foundation

// Identifies how fullscreen video playback should be sourced so the app can
// switch between direct and transcoded playback policies.
enum PlaybackMethod: String, CaseIterable, Identifiable {
    case directPlay
    case transcode

    var id: String { rawValue }
}

// Persists playback preferences so users can choose the default strategy until
// adaptive bandwidth selection is implemented.
final class PlaybackSettingsManager {
    static let shared = PlaybackSettingsManager()

    private let playbackMethodKey = "videoPlaybackMethod"

    private init() {}

    // Stores the preferred playback method that the temporary selector returns
    // before dynamic selection logic is available.
    var playbackMethod: PlaybackMethod {
        get {
            guard
                let stored = UserDefaults.standard.string(forKey: playbackMethodKey),
                let method = PlaybackMethod(rawValue: stored)
            else {
                return .directPlay
            }
            return method
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: playbackMethodKey)
            NotificationCenter.default.post(name: .playbackSettingsDidChange, object: nil)
        }
    }

    // Provides one selection hook for future bandwidth-aware mode switching
    // while currently honoring only the persisted user preference.
    static func selectPlaybackMethod(for _: TimelineItem) -> PlaybackMethod {
        shared.playbackMethod
    }
}

// Broadcasts playback setting changes so active fullscreen playback can switch
// behavior immediately after preference updates.
extension Notification.Name {
    static let playbackSettingsDidChange = Notification.Name("playbackSettingsDidChange")
}
