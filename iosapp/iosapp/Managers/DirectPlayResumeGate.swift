import Foundation

// Preserves user playback intent across direct-play range replacement so
// buffering updates do not leave fullscreen video unexpectedly paused.
struct DirectPlayResumeGate {
    private var isResumePending = false

    // Captures whether replacement interrupted active playback and tells the
    // caller if pausing is required while the new range buffers.
    mutating func handleReplacementStarted(isPlayingOrWaiting: Bool) -> Bool {
        isResumePending = isPlayingOrWaiting
        return isPlayingOrWaiting
    }

    // Emits a one-shot resume signal once replacement data becomes playable,
    // preventing repeated callbacks from forcing additional play() calls.
    mutating func handleReplacementReady() -> Bool {
        guard isResumePending else {
            return false
        }
        isResumePending = false
        return true
    }
}
