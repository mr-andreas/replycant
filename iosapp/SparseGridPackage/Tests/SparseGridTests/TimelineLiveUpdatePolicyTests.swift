import Testing
@testable import SparseGrid

// A timeline reload during deceleration cancels the flick. These cases
// lock when a structural update has to wait for that gesture to finish.
struct TimelineLiveUpdatePolicyTests {
    // The coast after the finger lifts is when an upload reload is felt.
    @Test func holdsWhileTheFlickIsCoasting() {
        #expect(
            TimelineLiveUpdatePolicy.shouldHold(
                isTracking: false,
                isDragging: false,
                isDecelerating: true,
                isGridScrolling: false,
                isProgrammaticJump: false
            )
        )
    }

    // The finger is still down, so a count change must not rebuild the grid.
    @Test func holdsWhileTheFingerIsDown() {
        #expect(
            TimelineLiveUpdatePolicy.shouldHold(
                isTracking: false,
                isDragging: true,
                isDecelerating: false,
                isGridScrolling: false,
                isProgrammaticJump: false
            )
        )
    }

    // A month jump is an animated scroll. Reloading it mid-flight drops the jump.
    @Test func holdsDuringAMonthJump() {
        #expect(
            TimelineLiveUpdatePolicy.shouldHold(
                isTracking: false,
                isDragging: false,
                isDecelerating: false,
                isGridScrolling: false,
                isProgrammaticJump: true
            )
        )
    }

    // A settled grid applies the upload immediately so the new photo appears.
    @Test func appliesWhenTheGridIsStill() {
        #expect(
            !TimelineLiveUpdatePolicy.shouldHold(
                isTracking: false,
                isDragging: false,
                isDecelerating: false,
                isGridScrolling: false,
                isProgrammaticJump: false
            )
        )
    }
}
