import Testing
@testable import iosapp

// Verifies direct-play seek replacement keeps playback intent so fullscreen
// video starts and resumes without extra user taps.
@Suite("DirectPlayResumeGate Tests")
struct DirectPlayResumeGateTests {
    // Ensures replacements that interrupt active playback ask the caller to
    // pause immediately and resume once replacement data is ready.
    @Test func resumesAfterReadyWhenPlaybackWasActive() {
        var gate = DirectPlayResumeGate()

        let shouldPause = gate.handleReplacementStarted(isPlayingOrWaiting: true)
        let shouldResume = gate.handleReplacementReady()

        #expect(shouldPause)
        #expect(shouldResume)
    }

    // Ensures replacements started while idle do not manufacture playback
    // intent, preserving the user's paused state.
    @Test func doesNotResumeWhenPlaybackWasIdle() {
        var gate = DirectPlayResumeGate()

        let shouldPause = gate.handleReplacementStarted(isPlayingOrWaiting: false)
        let shouldResume = gate.handleReplacementReady()

        #expect(!shouldPause)
        #expect(!shouldResume)
    }

    // Ensures each replacement cycle can trigger at most one resume so stale
    // callbacks cannot repeatedly force playback.
    @Test func resumesOnlyOncePerReplacementCycle() {
        var gate = DirectPlayResumeGate()

        _ = gate.handleReplacementStarted(isPlayingOrWaiting: true)
        let firstReady = gate.handleReplacementReady()
        let secondReady = gate.handleReplacementReady()

        #expect(firstReady)
        #expect(!secondReady)
    }
}
