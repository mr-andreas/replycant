import XCTest

// Captures the App Store timeline screenshot from fixture-backed demo media.
final class ScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    // Starts the app in screenshot fixture mode so the timeline grid is stable across runs.
    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        UITestFixtures.configureApp(app)
        app.launchArguments.append("--screenshots")
        setupSnapshot(app)
        app.launch()

        let fixturesReady = app.otherElements["uitest_fixtures_ready"]
        XCTAssertTrue(
            fixturesReady.waitForExistence(timeout: 180),
            "Fixture hydration did not complete before screenshot capture"
        )
    }

    // Releases app references between tests so each capture run starts clean.
    @MainActor
    override func tearDownWithError() throws {
        app = nil
    }

    // Captures the timeline grid with the month sidebar hidden and a slight scroll offset,
    // then the map of the same fixture library.
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        waitForFixturePhotos()
        captureTimelineScreenshot()
        captureMapScreenshot()
    }

    // Captures the timeline grid for the App Store listing without the month sidebar.
    @MainActor
    private func captureTimelineScreenshot() {
        activateTimelineTab()
        XCTAssertTrue(firstTimelinePhoto().waitForExistence(timeout: 120), "Expected timeline photos before capture")
        waitForContentToSettle(timeout: 45)
        ensureMonthSidebarHidden()

        // Startup anchors at the newest bottom edge; a short swipe-down reveals that the
        // library continues above instead of looking pinned flush to the end.
        let grid = app.descendants(matching: .any)["timelineGrid"].firstMatch
        let scrollTarget = grid.exists ? grid : firstTimelinePhoto()
        scrollTarget.swipeDown(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        waitForContentToSettle(timeout: 20)

        snapshot("01-timeline")
    }

    // Captures the place tiles so the listing shows browsing photos by location.
    @MainActor
    private func captureMapScreenshot() {
        tapTab(named: "Map", identifier: "mapTab")

        let placeTile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ photos$"))
            .firstMatch
        XCTAssertTrue(placeTile.waitForExistence(timeout: 60), "Expected place tiles on the map before capture")

        // Map tiles and tile photos load without a spinner, so the settle
        // check alone would capture grey placeholders.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        waitForContentToSettle(timeout: 20)

        snapshot("02-map")
    }

    // Keeps the month index closed so the grid owns the full screenshot width.
    @MainActor
    private func ensureMonthSidebarHidden() {
        let sidebarToggle = app.buttons["toggleTimelineMonthSidebarButton"]
        guard sidebarToggle.waitForExistence(timeout: 5) else { return }
        if sidebarToggle.label.lowercased().contains("hide"), sidebarToggle.isHittable {
            sidebarToggle.tap()
            waitForContentToSettle(timeout: 5)
        }
    }

    // Waits for seeded timeline photos before marketing capture.
    @MainActor
    private func waitForFixturePhotos() {
        let firstPhoto = firstTimelinePhoto()
        if firstPhoto.waitForExistence(timeout: 45) {
            waitForContentToSettle(timeout: 45)
            return
        }

        completeOnboardingIfNeeded()
        activateTimelineTab()

        let loadError = app.staticTexts["Failed to load timeline"]
        let emptyState = app.staticTexts["No photos uploaded yet"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if firstPhoto.exists {
                waitForContentToSettle(timeout: 45)
                return
            }
            if loadError.exists {
                XCTFail("Timeline failed to load during screenshot setup")
                return
            }
            if emptyState.exists {
                XCTFail("Timeline empty during screenshot setup despite fixtures")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTFail("Expected seeded timeline photos to appear")
    }

    // Activates the Timeline tab when the fixture launch does not land there already.
    @MainActor
    private func activateTimelineTab() {
        if firstTimelinePhoto().exists { return }
        tapTab(named: "Timeline", identifier: "timelineTab")
    }

    // Switches tabs on both iPhone and iPad layouts, falling back to a
    // coordinate tap when a tab exists but is not reported as hittable.
    @MainActor
    private func tapTab(named label: String, identifier: String) {
        let candidates: [XCUIElement] = [
            app.tabBars.buttons[label].firstMatch,
            app.tabBars.buttons[identifier].firstMatch,
            app.buttons[label].firstMatch
        ]

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            for candidate in candidates where candidate.exists && candidate.isHittable {
                candidate.tap()
                return
            }
            for candidate in candidates where candidate.exists {
                candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("Expected \(label) tab to become available")
    }

    // Waits for LFS-backed thumbnails to finish loading before capturing marketing screenshots.
    @MainActor
    private func waitForContentToSettle(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var idleSince: Date?
        while Date() < deadline {
            if app.activityIndicators.count == 0 {
                if idleSince == nil {
                    idleSince = Date()
                }
                if let idleSince, Date().timeIntervalSince(idleSince) >= 1.5 {
                    return
                }
            } else {
                idleSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
    }

    @MainActor
    private func firstTimelinePhoto() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "timelinePhoto_p-"))
            .firstMatch
    }

    // Advances onboarding screens in simulator-driven runs where launch env flags are ignored.
    @MainActor
    private func completeOnboardingIfNeeded() {
        let nextButton = app.buttons["Next"]
        for _ in 0..<3 where nextButton.waitForExistence(timeout: 3) {
            nextButton.tap()
        }

        let getStartedButton = app.buttons["Get Started"]
        if getStartedButton.waitForExistence(timeout: 3) {
            getStartedButton.tap()
        }

        let createButton = app.buttons["Create a new library"]
        if createButton.waitForExistence(timeout: 10) {
            createButton.tap()
        }
    }
}
