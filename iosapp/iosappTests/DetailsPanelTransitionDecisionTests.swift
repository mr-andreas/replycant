import XCTest
@testable import iosapp

// Verifies the show/hide threshold logic so panel gestures feel responsive
// and deterministic for short nudges.
final class DetailsPanelTransitionDecisionTests: XCTestCase {

    func testShouldShow_allowsShortFastUpwardNudge() {
        XCTAssertTrue(
            DetailsPanelTransitionDecision.shouldShow(
                translationY: -15,
                velocityY: -700
            )
        )
    }

    func testShouldShow_allowsLongUpwardDrag() {
        XCTAssertTrue(
            DetailsPanelTransitionDecision.shouldShow(
                translationY: -80,
                velocityY: -50
            )
        )
    }

    func testShouldShow_rejectsSmallSlowDrag() {
        XCTAssertFalse(
            DetailsPanelTransitionDecision.shouldShow(
                translationY: -20,
                velocityY: -100
            )
        )
    }

    func testShouldHide_allowsShortFastDownwardNudge() {
        XCTAssertTrue(
            DetailsPanelTransitionDecision.shouldHide(
                translationY: 12,
                velocityY: 650
            )
        )
    }

    func testShouldHide_allowsLongDownwardDrag() {
        XCTAssertTrue(
            DetailsPanelTransitionDecision.shouldHide(
                translationY: 70,
                velocityY: 40
            )
        )
    }

    func testShouldHide_rejectsSmallSlowDrag() {
        XCTAssertFalse(
            DetailsPanelTransitionDecision.shouldHide(
                translationY: 18,
                velocityY: 120
            )
        )
    }
}
