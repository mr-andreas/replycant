import Foundation
import XCTest

// UI Test fixtures for setting up git repository and mock LFS server
class UITestFixtures {
    
    // Sets up app with test repository via launch arguments
    static func configureApp(_ app: XCUIApplication) {
        // Signal to the app that it should use test data
        app.launchArguments = ["--uitesting"]
        
        // Pass test repository path via environment
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["SKIP_ONBOARDING"] = "1"
        // Leave TEST_GIT_URL unset so TestSupport points git/LFS at the
        // in-process TestLFSServer instead of an unreachable placeholder.
    }
    
    // Creates test repository in app's documents directory
    static func setupTestRepository(for app: XCUIApplication) throws {
        // The app will be running in a simulator, so we need to create
        // the test repository programmatically when the app launches
        // This is handled by the app itself when it detects TEST_MODE
        configureApp(app)
    }
    
    // Waits for the real timeline grid so launch-position assertions use the production accessibility id.
    static func waitForTimelineLoad(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        let timeline = app.collectionViews["timelineGrid"]
        let exists = timeline.waitForExistence(timeout: timeout)
        XCTAssertTrue(exists, "Timeline should load within \(timeout) seconds")
    }
    
    // Helper to wait for photos to appear
    static func waitForPhotos(_ app: XCUIApplication, count: Int = 1, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(format: "count >= %d", count)
        let images = app.images.matching(identifier: "timelinePhoto")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: images)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected at least \(count) photos to appear")
    }
}


