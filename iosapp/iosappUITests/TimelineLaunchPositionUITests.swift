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
}
