import XCTest

// Verifies timeline launch starts on newest rows instead of flashing from the oldest rows.
final class TimelineLaunchPositionUITests: XCTestCase {
    private var app: XCUIApplication!

    // Boots the app with hydrated fixtures so launch-position checks run against deterministic media ordering.
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

    // Clears the app reference between tests so each run gets a clean launch state.
    override func tearDownWithError() throws {
        app = nil
    }

    // Confirms the first visible timeline cells are from the newest end at app startup.
    func testTimelineLaunchShowsNewestItems() throws {
        UITestFixtures.waitForTimelineLoad(app, timeout: 15)

        let newestFixture = app.collectionViews["timelineGrid"]
            .cells
            .matching(identifier: "timelinePhoto_v-1")
            .firstMatch
        XCTAssertTrue(
            newestFixture.waitForExistence(timeout: 10),
            "Newest fixture should be visible at launch"
        )

        let oldestFixture = app.descendants(matching: .any)["timelinePhoto_o-01"]
        XCTAssertFalse(
            oldestFixture.exists && oldestFixture.isHittable,
            "Oldest fixture should not be visible at launch"
        )
    }

    // Confirms bottom inset leaves the newest row visible above the tab bar when launch anchors to the end.
    func testTimelineLaunchBottomItemSitsAboveTabBar() throws {
        UITestFixtures.waitForTimelineLoad(app, timeout: 15)

        let timelineGrid = app.collectionViews["timelineGrid"]
        XCTAssertTrue(timelineGrid.waitForExistence(timeout: 10), "Expected timeline grid at launch")

        let newestCandidates = timelineGrid.descendants(matching: .any)
            .matching(identifier: "timelinePhoto_v-1")
            .allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
        XCTAssertFalse(newestCandidates.isEmpty, "Newest fixture should be visible at launch")
        guard let newestFixture = newestCandidates.max(by: { $0.frame.maxY < $1.frame.maxY }) else {
            XCTFail("Expected at least one resolved newest fixture element")
            return
        }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "Expected tab bar to exist")
        XCTAssertLessThanOrEqual(
            newestFixture.frame.maxY,
            tabBar.frame.minY + 1,
            "Newest fixture should not be covered by the tab bar"
        )
    }

    // Switching back from another tab is a different gesture from re-tapping
    // the current one, and it has to leave the photos the user was looking at.
    func testSwitchingBackToTimelineKeepsPosition() throws {
        UITestFixtures.waitForTimelineLoad(app, timeout: 15)
        scrollUntilOldestFixtureIsHittable()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "Expected Settings tab")
        settingsTab.tap()

        app.tabBars.buttons["Timeline"].tap()
        UITestFixtures.waitForTimelineLoad(app, timeout: 10)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            XCTAssertNotNil(
                hittableTimelinePhoto("o-01"),
                "Returning to Timeline from another tab should keep the current photos on screen"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    // The cell and its image view share an identifier, so a single query is
    // ambiguous and reports itself as not hittable. One of the matches is
    // the photo the user can tap.
    private func hittableTimelinePhoto(_ name: String) -> XCUIElement? {
        app.descendants(matching: .any)
            .matching(identifier: "timelinePhoto_\(name)")
            .allElementsBoundByIndex
            .first { $0.isHittable }
    }

    // Moves off the launch position, which is already the newest row, so a
    // later tap has somewhere to scroll back from. A full swipe reaches the
    // top and keeps pulling, and that refresh reloads the grid at the newest
    // row, so the drag is short and held.
    private func scrollUntilOldestFixtureIsHittable() {
        let timelineGrid = app.collectionViews["timelineGrid"]
        let start = timelineGrid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
        let end = timelineGrid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        for _ in 0..<6 {
            if hittableTimelinePhoto("o-01") != nil {
                return
            }
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let details = app.descendants(matching: .any)
            .matching(identifier: "timelinePhoto_o-01")
            .allElementsBoundByIndex
            .map { "hittable=\($0.isHittable) frame=\($0.frame)" }
            .joined(separator: "; ")
        XCTAssertNotNil(
            hittableTimelinePhoto("o-01"),
            "Oldest fixture should be reachable by scrolling toward older photos (\(details))"
        )
    }
}
