import XCTest

// Verifies toggling the month sidebar preserves the visible timeline anchor position.
final class TimelineSidebarTogglePositionUITests: XCTestCase {
    private var app: XCUIApplication!

    // Boots fixture-backed timeline state so sidebar toggle assertions run on deterministic data.
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        UITestFixtures.configureApp(app)
        app.launch()

        let fixturesReady = app.otherElements["uitest_fixtures_ready"]
        XCTAssertTrue(
            fixturesReady.waitForExistence(timeout: 45),
            "Fixture hydration did not complete - check TestSupport logs"
        )
    }

    // Releases app reference between tests so each run starts from a fresh launch.
    override func tearDownWithError() throws {
        app = nil
    }

    // Ensures overlaying the sidebar keeps the grid frame stable and preserves the visible top anchor.
    func testSidebarTogglePreservesTopVisibleAnchor() {
        UITestFixtures.waitForTimelineLoad(app, timeout: 15)
        let timelineGrid = app.collectionViews["timelineGrid"]
        let toggleButton = app.buttons["toggleTimelineMonthSidebarButton"]
        let sidebar = app.descendants(matching: .any).matching(identifier: "timelineMonthSidebar").firstMatch

        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5), "Expected sidebar toggle button")

        // Move away from the initial viewport so we can catch anchor drift at a non-trivial position.
        for _ in 0..<6 {
            timelineGrid.swipeDown()
        }

        let baselineGridFrame = timelineGrid.frame
        let beforeShow = tryAnchor(in: timelineGrid)
        XCTAssertNotNil(beforeShow, "Expected a visible timeline anchor before showing sidebar")

        toggleButton.tap()
        XCTAssertTrue(waitForSidebar(sidebar, visible: true, timeout: 10), "Sidebar should appear")
        assertSidebarFillsScreenHeight(sidebar, context: "show")
        assertFramesNearlyEqual(
            baselineGridFrame,
            timelineGrid.frame,
            tolerance: 1,
            context: "show"
        )

        let afterShow = tryAnchor(in: timelineGrid)
        XCTAssertNotNil(afterShow, "Expected a visible timeline anchor after showing sidebar")
        assertAnchorsEqual(beforeShow!, afterShow!, yTolerance: 4, context: "show")

        toggleButton.tap()
        XCTAssertTrue(waitForSidebar(sidebar, visible: false, timeout: 5), "Sidebar should hide")
        assertFramesNearlyEqual(
            baselineGridFrame,
            timelineGrid.frame,
            tolerance: 1,
            context: "hide"
        )

        let afterHide = tryAnchor(in: timelineGrid)
        XCTAssertNotNil(afterHide, "Expected a visible timeline anchor after hiding sidebar")
        assertAnchorsEqual(afterShow!, afterHide!, yTolerance: 4, context: "hide")
    }

    // Captures the visually top-most visible timeline cell and its offset from the grid's top edge.
    private func tryAnchor(in timelineGrid: XCUIElement) -> (id: String, yFromGridTop: CGFloat)? {
        let timelineElements = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "timelinePhoto_"))
            .allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
            .filter { $0.frame.maxY > timelineGrid.frame.minY && $0.frame.minY < timelineGrid.frame.maxY }

        guard let top = timelineElements.min(by: { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > 0.5 {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }) else {
            return nil
        }

        return (id: top.identifier, yFromGridTop: top.frame.minY - timelineGrid.frame.minY)
    }

    // Validates that sidebar toggling preserves both item identity and near-identical vertical anchor position.
    private func assertAnchorsEqual(_ lhs: (id: String, yFromGridTop: CGFloat), _ rhs: (id: String, yFromGridTop: CGFloat), yTolerance: CGFloat, context: String) {
        XCTAssertEqual(lhs.id, rhs.id, "Top anchor id changed unexpectedly during \(context) toggle")
        XCTAssertLessThanOrEqual(abs(lhs.yFromGridTop - rhs.yFromGridTop), yTolerance, "Top anchor y-offset drifted during \(context) toggle")
    }

    // Confirms sidebar visibility no longer resizes the timeline viewport now that it overlays content.
    private func assertFramesNearlyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat, context: String) {
        XCTAssertLessThanOrEqual(abs(lhs.minX - rhs.minX), tolerance, "Grid minX changed during \(context) toggle")
        XCTAssertLessThanOrEqual(abs(lhs.minY - rhs.minY), tolerance, "Grid minY changed during \(context) toggle")
        XCTAssertLessThanOrEqual(abs(lhs.width - rhs.width), tolerance, "Grid width changed during \(context) toggle")
        XCTAssertLessThanOrEqual(abs(lhs.height - rhs.height), tolerance, "Grid height changed during \(context) toggle")
    }

    // Confirms the sidebar background extends behind nav and tab bars by verifying content is within safe area.
    private func assertSidebarFillsScreenHeight(_ sidebar: XCUIElement, context: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Expected a visible app window during \(context)")
        XCTAssertGreaterThanOrEqual(sidebar.frame.minY, window.frame.minY, "Sidebar top should be at or below window top during \(context)")
        XCTAssertLessThanOrEqual(sidebar.frame.maxY, window.frame.maxY, "Sidebar bottom should be at or above window bottom during \(context)")
    }

    // Waits for sidebar visibility changes without assuming element type.
    private func waitForSidebar(_ sidebar: XCUIElement, visible: Bool, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: visible))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: sidebar)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
