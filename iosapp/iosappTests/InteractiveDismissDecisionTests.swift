import XCTest
@testable import iosapp

// Verifies dismiss intent heuristics so gesture arbitration stays predictable across media views.
final class InteractiveDismissDecisionTests: XCTestCase {

    // Confirms downward vertical velocity at top-level scale starts the dismiss recognizer.
    func testShouldBegin_allowsDownwardVerticalIntent() {
        XCTAssertTrue(
            InteractiveDismissDecision.shouldBegin(
                velocity: CGPoint(x: 100, y: 1000),
                scale: 1.0,
                scrollOffset: 0
            )
        )
    }

    // Confirms horizontal-dominant swipes are rejected so TabView paging can win.
    func testShouldBegin_rejectsHorizontalIntent() {
        XCTAssertFalse(
            InteractiveDismissDecision.shouldBegin(
                velocity: CGPoint(x: 900, y: 300),
                scale: 1.0,
                scrollOffset: 0
            )
        )
    }

    // Confirms upward flicks do not trigger dismiss start.
    func testShouldBegin_rejectsUpwardVelocity() {
        XCTAssertFalse(
            InteractiveDismissDecision.shouldBegin(
                velocity: CGPoint(x: 10, y: -900),
                scale: 1.0,
                scrollOffset: 0
            )
        )
    }

    // Confirms dismiss is blocked when content is zoomed and should pan instead.
    func testShouldBegin_rejectsZoomedContent() {
        XCTAssertFalse(
            InteractiveDismissDecision.shouldBegin(
                velocity: CGPoint(x: 50, y: 950),
                scale: 1.4,
                scrollOffset: 0
            )
        )
    }

    // Confirms dismiss is blocked when metadata is scrolled below the top.
    func testShouldBegin_rejectsWhenScrolledDown() {
        XCTAssertFalse(
            InteractiveDismissDecision.shouldBegin(
                velocity: CGPoint(x: 30, y: 900),
                scale: 1.0,
                scrollOffset: -220
            )
        )
    }

    // Confirms translation progress clamps to [0, 1] for stable animation values.
    func testProgress_clampsRange() {
        XCTAssertEqual(InteractiveDismissDecision.progress(translationY: -20), 0)
        XCTAssertEqual(InteractiveDismissDecision.progress(translationY: 75), 0.5, accuracy: 0.001)
        XCTAssertEqual(InteractiveDismissDecision.progress(translationY: 500), 1)
    }

    // Confirms long drags commit dismiss even without high release velocity.
    func testShouldDismiss_allowsLargeTranslation() {
        XCTAssertTrue(InteractiveDismissDecision.shouldDismiss(translationY: 180, velocityY: 100))
    }

    // Confirms quick downward flicks commit dismiss even with short drag distance.
    func testShouldDismiss_allowsHighVelocityFlick() {
        XCTAssertTrue(InteractiveDismissDecision.shouldDismiss(translationY: 35, velocityY: 1200))
    }

    // Confirms upward release cancels dismiss to support reversal behavior.
    func testShouldDismiss_rejectsReversingVelocity() {
        XCTAssertFalse(InteractiveDismissDecision.shouldDismiss(translationY: 220, velocityY: -50))
    }
}
