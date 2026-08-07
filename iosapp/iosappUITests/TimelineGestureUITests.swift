//
//  TimelineGestureUITests.swift
//  iosappUITests
//
//  Tests for gesture interactions in the timeline photo viewer
//

import XCTest

final class TimelineGestureUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        
        // Set up test environment with fixtures
        UITestFixtures.configureApp(app)
        
        app.launch()

        let fixturesReady = app.otherElements["uitest_fixtures_ready"]
        XCTAssertTrue(
            fixturesReady.waitForExistence(timeout: 45),
            "Fixture hydration did not complete - check TestSupport logs"
        )
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Helper Methods

    // Reports which timeline state is on screen when a fixture wait expires.
    //
    // The app's own logging is not captured while UI tests run, and a missing
    // cell looks identical whether the timeline is still loading, failed with
    // an error, believes it has no photos, or rendered a grid that simply does
    // not contain the expected item. Naming the state turns a bare timeout into
    // something diagnosable from the CI log alone.
    private func timelineStateDescription() -> String {
        let states = [
            "loading": app.staticTexts["Loading timeline..."].exists,
            "error": app.staticTexts["Failed to load timeline"].exists,
            "empty": app.staticTexts["No photos uploaded yet"].exists,
            "grid": app.collectionViews["timelineGrid"].exists,
        ]
        let active = states.filter(\.value).keys.sorted().joined(separator: ",")
        let labels = app.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .prefix(8)
            .joined(separator: " | ")
        return "state=[\(active.isEmpty ? "none" : active)] labels=[\(labels)]"
    }
    
    // Navigate to timeline and open first image
    func navigateToFirstImage() throws {
        let timelineTab = app.tabBars.buttons["Timeline"]
        if timelineTab.waitForExistence(timeout: 5) {
            timelineTab.tap()
        }
        
        let firstButton = app.buttons["timelinePhoto_i-1"]
        let firstCell = app.collectionViews.cells["timelinePhoto_i-1"]
        XCTAssertTrue(
            firstButton.waitForExistence(timeout: UITestFixtures.uiSettleTimeout)
                || firstCell.waitForExistence(timeout: 1),
            "First timeline fixture should exist (\(timelineStateDescription()))"
        )
        if firstButton.exists && firstButton.isHittable {
            firstButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            firstCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        
        // Verify we're viewing a photo in full screen.
        let fullScreenImage = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        var didOpenPhoto = fullScreenImage.waitForExistence(timeout: 5)
        if !didOpenPhoto, firstCell.exists {
            firstCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            didOpenPhoto = fullScreenImage.waitForExistence(timeout: 10)
        }
        if !didOpenPhoto {
            let failedLoad = app.staticTexts["Failed to load image"].exists
            let repoError = app.staticTexts["Repository not available"].exists
            let lfsError = app.staticTexts["LFS client not available"].exists
            let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).prefix(12).joined(separator: " | ")
            XCTFail(
                "Should be in full screen photo view (failedLoad=\(failedLoad), repoError=\(repoError), lfsError=\(lfsError), labels=\(labels))"
            )
            return
        }
        XCTAssertTrue(didOpenPhoto, "Should be in full screen photo view")
    }

    func navigateToSecondImage() throws {
        let timelineTab = app.tabBars.buttons["Timeline"]
        if timelineTab.waitForExistence(timeout: 5) {
            timelineTab.tap()
        }
        
        let secondButton = app.buttons["timelinePhoto_i-2"]
        let secondCell = app.collectionViews.cells["timelinePhoto_i-2"]
        XCTAssertTrue(
            secondButton.waitForExistence(timeout: UITestFixtures.uiSettleTimeout)
                || secondCell.waitForExistence(timeout: 1),
            "Second timeline fixture should exist (\(timelineStateDescription()))"
        )
        if secondButton.exists && secondButton.isHittable {
            secondButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            secondCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        
        // Verify we're viewing a photo in full screen.
        let fullScreenImage = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        var didOpenPhoto = fullScreenImage.waitForExistence(timeout: 5)
        if !didOpenPhoto, secondCell.exists {
            secondCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            didOpenPhoto = fullScreenImage.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(didOpenPhoto, "Should be in full screen photo view")
    }
    
    // MARK: - Swipe to Dismiss Tests
    
    // Verifies that a long vertical swipe down from the center of the image
    // dismisses the full-screen view and returns to the timeline grid.
    // This is the primary gesture for closing an image without using the X button.
    @MainActor
    func testVerticalSwipeDownDismissesImage() throws {
        try navigateToFirstImage()
        
        // Get the zoomable image view (this is the actual photo in full screen)
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.exists, "Zoomable image should be displayed in full screen")
        
        // Perform a vertical swipe down from center
        let startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2.0))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        
        // Wait for animation and verify dismissal
        Thread.sleep(forTimeInterval: 0.5)
        
        // Should be back at timeline grid - verify full screen is gone
        let fullScreenView = app.otherElements["fullScreenImage"]
        XCTAssertFalse(fullScreenView.exists, "Full screen view should be dismissed")
        
        // And timeline photo button should be visible again
        let timelinePhoto = app.descendants(matching: .any)["timelinePhoto_i-1"]
        XCTAssertTrue(timelinePhoto.exists, "Should be back at timeline grid")
    }
    
    // Verifies that a short vertical swipe (less than the dismiss threshold)
    // does not dismiss the image. This prevents accidental dismissals from
    // small unintentional swipe movements.
    @MainActor
    func testShortVerticalSwipeDoesNotDismiss() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.exists)
        
        // Perform a short vertical swipe (should not dismiss)
        let startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        
        Thread.sleep(forTimeInterval: 0.5)
        
        // Should still be in full screen view
        XCTAssertTrue(imageView.exists, "Image should still be visible after short swipe")
    }

    // Verifies that a quick downward flick can dismiss even with shorter travel distance.
    // This matches the velocity-based dismiss behavior in the interactive recognizer.
    @MainActor
    func testFastFlickDismissesWithShortTravel() throws {
        try navigateToFirstImage()

        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.exists, "Zoomable image should be visible before flick test")

        // Use a brief press + fast drag to simulate a downward flick release.
        let startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.6))
        startPoint.press(forDuration: 0.01, thenDragTo: endPoint)

        Thread.sleep(forTimeInterval: 0.5)

        let fullScreenView = app.otherElements["fullScreenImage"]
        XCTAssertFalse(fullScreenView.exists, "Fast flick should dismiss full screen media")
    }
    
    // Verifies that swiping upward does not dismiss the image.
    // Upward swipes should scroll to view the metadata section below the image,
    // not trigger the dismiss gesture.
    @MainActor
    func testUpwardSwipeDoesNotDismiss() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.exists)
        
        // Perform upward swipe (should scroll metadata, not dismiss)
        let startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        
        Thread.sleep(forTimeInterval: 0.5)
        
        // Should still be in full screen view
        XCTAssertTrue(imageView.exists, "Image should still be visible after upward swipe")
    }
    
    // CRITICAL TEST: Verifies that after scrolling down to view metadata (swipe up),
    // swiping down scrolls back to the image instead of dismissing the view.
    // This prevents accidental dismissals when the user has scrolled to view details.
    @MainActor
    func testSwipeDownAfterViewingMetadataScrollsBackInsteadOfDismissing() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.exists, "Image should be visible")
        
        // Step 1: Swipe up to scroll down and view the metadata section
        let swipeUpStart = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let swipeUpEnd = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        swipeUpStart.press(forDuration: 0.1, thenDragTo: swipeUpEnd)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Verify we're still in full screen view (didn't dismiss)
        XCTAssertTrue(imageView.exists, "Image should still be visible after scrolling to metadata")
        
        // Step 2: Now swipe down to scroll back up to the image
        // This should scroll the view back, NOT dismiss the image
        let swipeDownStart = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let swipeDownEnd = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        swipeDownStart.press(forDuration: 0.1, thenDragTo: swipeDownEnd)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Should still be in full screen view - NOT dismissed
        XCTAssertTrue(imageView.exists, "Image should still be visible after scrolling back from metadata")
        
        // Verify we haven't returned to timeline (which would indicate incorrect dismiss)
        let fullScreenView = app.otherElements["fullScreenImage"]
        XCTAssertTrue(fullScreenView.exists, "Should still be in full screen view, not dismissed")
    }
    
    // MARK: - Horizontal Navigation Tests
    
    // Verifies that swiping left horizontally navigates to the next image
    // in the timeline. This uses the TabView's built-in paging gesture.
    @MainActor
    func testHorizontalSwipeNavigatesBetweenImages() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.exists)
        
        // Capture initial image ID (should be "i-1")
        let initialLabel = imageView.label
        XCTAssertEqual(initialLabel, "i-1", "Should start on first image")
        
        // Swipe left to go to next image
        let startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        
        Thread.sleep(forTimeInterval: 0.5)
        
        // Should have navigated to the next image (i-2)
        let newImageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(newImageView.exists, "Should still be viewing an image after horizontal swipe")
        let newLabel = newImageView.label
        XCTAssertNotEqual(newLabel, initialLabel, "Should have navigated to a different image")
        XCTAssertEqual(newLabel, "i-2", "Should have navigated to second image")
    }
    
    // Verifies that swiping right horizontally navigates back to the previous
    // image in the timeline. Tests bidirectional navigation.
    @MainActor
    func testHorizontalSwipeRightNavigatesBack() throws {
        try navigateToFirstImage()
        
        // Capture initial image ID (should be "i-1")
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        let initialLabel = imageView.label
        XCTAssertEqual(initialLabel, "i-1", "Should start on first image")
        
        // Swipe left to next image
        var startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        var endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Verify we navigated to the next image (i-2)
        let imageViewAfterLeft = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        let labelAfterLeft = imageViewAfterLeft.label
        XCTAssertEqual(labelAfterLeft, "i-2", "Should have navigated to second image")
        
        // Now swipe right to go back
        startPoint = imageViewAfterLeft.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        endPoint = imageViewAfterLeft.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Verify we navigated back to the first image (i-1)
        let imageViewAfterRight = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageViewAfterRight.exists, "Should still be viewing an image")
        let finalLabel = imageViewAfterRight.label
        XCTAssertEqual(finalLabel, initialLabel, "Should have navigated back to first image")
        XCTAssertEqual(finalLabel, "i-1", "Should be back on first image")
    }
    
    // MARK: - Gesture Isolation Tests
    
    
    // CRITICAL TEST: Verifies that a diagonal swipe (down and right simultaneously)
    // triggers ONLY ONE gesture - either dismiss OR navigate, but NOT BOTH.
    // This was the original bug: both gestures could activate at the same time.
    // The direction-locking mechanism should pick the more dominant direction.
    @MainActor
    func testDiagonalSwipeDownRightDoesNotDismissAndNavigate() throws {
        try navigateToSecondImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        let initialExists = imageView.exists
        XCTAssertTrue(initialExists)
        
        // Perform diagonal swipe (right with slight downward drift).
        let startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
        let endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        
        Thread.sleep(forTimeInterval: 0.5)
        
        // Verify that the image view has not been dismissed
        XCTAssertTrue(imageView.exists, "Image should still exist after diagonal swipe")

        // Verify that we're viewing i-1
        let label = imageView.label
        XCTAssertEqual(label, "i-1", "Should be viewing i-1")

        // Perform a second, stronger diagonal swipe (left but mostly down)
        // to ensure dismiss wins over paging in UI test timing.
        let startPoint2 = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2))
        let endPoint2 = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 1.4))
        startPoint2.press(forDuration: 0.1, thenDragTo: endPoint2)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Verify that the image view has been dismissed
        XCTAssertFalse(imageView.exists, "Image should have been dismissed after second diagonal swipe")
        
    }
    
    // MARK: - Double Tap Zoom Tests
    
    // Verifies that double-tapping the image zooms in to 2.5x scale.
    // After zooming in, swipe gestures should pan the image instead of dismissing.
    @MainActor
    func testDoubleTapZoomsIn() throws {
        try navigateToFirstImage()
        
        // Get the zoomable image view (this is the actual photo in full screen)
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.waitForExistence(timeout: 3), "Zoomable image should be displayed in full screen")
        
        // Double tap to zoom in using coordinates to avoid scroll-to-visible issues
        let tapPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.doubleTap()
        
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the image is zoomed in by checking accessibility value
        XCTAssertEqual(imageView.value as? String, "zoomed", "Image should be zoomed in")
        
        // After zooming, vertical swipe should pan, not dismiss
        // We can't directly measure scale, but we can verify the image still exists
        XCTAssertTrue(imageView.exists, "Image should still exist after double tap zoom")
    }
    
    // Verifies that double-tapping a zoomed image returns it to 1.0x scale (zooms out).
    // This provides an easy way to reset the zoom level.
    @MainActor
    func testDoubleTapAgainZoomsOut() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.waitForExistence(timeout: 3), "Zoomable image should be displayed")
        
        // Double tap to zoom in using coordinates
        let tapPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the image is zoomed in by checking accessibility value
        XCTAssertEqual(imageView.value as? String, "zoomed", "Image should be zoomed in")
        
        // Double tap again to zoom out
        tapPoint.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)
        
        // Verify the image is zoomed out by checking accessibility value
        XCTAssertEqual(imageView.value as? String, "normal", "Image should be zoomed out")
        
        XCTAssertTrue(imageView.exists, "Image should still exist after zooming out")
    }
    
    // MARK: - Pinch Gesture Tests
    
    // Verifies that a pinch-out gesture (spreading two fingers apart) zooms into the image.
    // Note: Pinch gestures are notoriously unreliable in UI tests due to the difficulty
    // of simulating simultaneous multi-touch input. This test may be flaky.
    @MainActor
    func testPinchToZoom() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.exists)
        
        imageView.pinch(withScale: 1.5, velocity: 1.0)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Verify the image is zoomed in by checking accessibility value
        XCTAssertEqual(imageView.value as? String, "zoomed", "Image should be zoomed in")
    }
    
    // Verifies that a pinch-in gesture (bringing two fingers together) zooms out of the image.
    // This test first zooms in via double-tap (to 2.5x), then pinches out to return to normal.
    // Note: Pinch scale of 0.3 is used because 2.5 × 0.3 = 0.75, which snaps back to 1.0.
    @MainActor
    func testPinchOutZoomsOut() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.waitForExistence(timeout: 3), "Zoomable image should be displayed")
        
        // First zoom in with double tap (more reliable) using coordinates
        let tapPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the image is zoomed in by checking accessibility value
        XCTAssertEqual(imageView.value as? String, "zoomed", "Image should be zoomed in")

        // Pinch out to zoom back to normal (scale 0.3 ensures 2.5 × 0.3 = 0.75 < 1.0, snaps to 1.0)
        imageView.pinch(withScale: 0.3, velocity: -1.0)
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the image is zoomed out by checking accessibility value
        XCTAssertEqual(imageView.value as? String, "normal", "Image should be zoomed out")

        XCTAssertTrue(imageView.exists, "Image should still exist after zooming out")
    }
    
    // MARK: - Pan When Zoomed Tests
    
    // Verifies that when the image is zoomed in (scale > 1.0), vertical drag gestures
    // pan the zoomed image instead of triggering the dismiss gesture.
    // This ensures users can explore zoomed images without accidentally closing them.
    @MainActor
    func testPanWhenZoomedDoesNotDismiss() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(imageView.waitForExistence(timeout: 3), "Zoomable image should be displayed")
        
        // Zoom in first using coordinates
        let tapPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the image is zoomed in by checking accessibility value
        XCTAssertEqual(imageView.value as? String, "zoomed", "Image should be zoomed in")
        
        // Try to swipe down (should pan, not dismiss when zoomed)
        let startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        
        Thread.sleep(forTimeInterval: 0.5)
        
        // Should still be viewing the image (not dismissed)
        XCTAssertTrue(imageView.exists, "Zoomed image should not dismiss on vertical drag")
    }


    
    // Panning left/right when zoomed should move the image left/right, not
    // navigate to the next/previous image until we reach the edge of the image.
    @MainActor
    func testHorizontalPanWhenZoomed() throws {
        try navigateToFirstImage()
        
        let imageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        let initialLabel = imageView.label
        XCTAssertTrue(imageView.waitForExistence(timeout: 3), "Zoomable image should be displayed")
        
        // Zoom in first using coordinates
        let tapPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the image is zoomed in by checking accessibility value
        XCTAssertEqual(imageView.value as? String, "zoomed", "Image should be zoomed in")

        // Swipe left first
        let startPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let endPoint = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        Thread.sleep(forTimeInterval: 0.5)

        // Should still be viewing the same image (not another one)
        let finalImageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(finalImageView.exists, "Image should still exist after horizontal pan when zoomed")
        XCTAssertEqual(finalImageView.label, initialLabel, "Should still be viewing the same image after pan when zoomed")
    }
    
    // MARK: - Video Playback Tests
    
    // Verifies that swiping down on a video dismisses the full-screen view,
    // matching the behavior of images. This provides a consistent UX for
    // dismissing any media type with the same gesture.
    @MainActor
    func testSwipeDownDismissesVideo() throws {
        // Navigate to timeline
        let timelineTab = app.tabBars.buttons["Timeline"]
        if timelineTab.waitForExistence(timeout: 5) {
            timelineTab.tap()
        }
        
        // Wait for timeline to load and find the video button
        let videoButton = app.buttons["timelinePhoto_v-1"]
        let videoCell = app.collectionViews.cells["timelinePhoto_v-1"]
        XCTAssertTrue(
            videoButton.waitForExistence(timeout: 10) || videoCell.waitForExistence(timeout: 1),
            "Video fixture should exist"
        )
        
        // Open video directly from timeline grid
        if videoButton.exists && videoButton.isHittable {
            videoButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            videoCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        Thread.sleep(forTimeInterval: 2.0) // Wait for video to start loading/playing
        
        // Verify we're viewing the video in full screen
        let fullScreenView = app.otherElements["fullScreenImage"]
        XCTAssertTrue(fullScreenView.waitForExistence(timeout: 5), "Should be in full screen view for video")
        
        // Get the video player
        let videoPlayer = app.descendants(matching: .any).matching(identifier: "videoPlayer").firstMatch
        XCTAssertTrue(videoPlayer.waitForExistence(timeout: 10), "Video player should be displayed")
        
        // Perform a vertical swipe down from center to dismiss
        let startPoint = videoPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let endPoint = videoPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.5))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        
        // Wait for animation
        Thread.sleep(forTimeInterval: 0.5)
        
        // Should be back at timeline grid - verify full screen is gone
        XCTAssertFalse(fullScreenView.exists, "Full screen view should be dismissed after swipe down on video")
        
        // And timeline video button should be visible again
        XCTAssertTrue(videoButton.exists, "Should be back at timeline grid")
    }
    
    // Verifies that when viewing a video and swiping to the next image,
    // the video stops playing. This prevents videos from continuing to play
    // in the background when they're no longer visible.
    @MainActor
    func testVideoStopsPlayingWhenSwipedAway() throws {
        // Navigate to timeline
        let timelineTab = app.tabBars.buttons["Timeline"]
        if timelineTab.waitForExistence(timeout: 5) {
            timelineTab.tap()
        }
        
        // Wait for timeline to load and find the video button
        let videoButton = app.buttons["timelinePhoto_v-1"]
        let videoCell = app.collectionViews.cells["timelinePhoto_v-1"]
        XCTAssertTrue(
            videoButton.waitForExistence(timeout: 10) || videoCell.waitForExistence(timeout: 1),
            "Video fixture should exist"
        )
        
        // Open video directly from timeline grid
        if videoButton.exists && videoButton.isHittable {
            videoButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            videoCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        Thread.sleep(forTimeInterval: 2.0) // Wait for video to start loading/playing
        
        // Verify we're viewing the video in full screen
        let fullScreenView = app.otherElements["fullScreenImage"]
        XCTAssertTrue(fullScreenView.waitForExistence(timeout: 5), "Should be in full screen view for video")
        
        // Verify we're on the video (zoomableImage should not exist for videos)
        let videoImageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertFalse(videoImageView.exists, "Should be viewing video (zoomableImage should not exist for videos)")

        // Get the video player and make sure it's playing
        let videoPlayer = app.descendants(matching: .any).matching(identifier: "videoPlayer").firstMatch
        XCTAssertTrue(videoPlayer.waitForExistence(timeout: 10), "Video player should be displayed")
        XCTAssertEqual(videoPlayer.value as? String, "playing", "Video player should be playing")
        
        // Now swipe to the previous item (should navigate to a photo)
        let swipeArea = fullScreenView
        let startPoint = swipeArea.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let endPoint = swipeArea.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)
        Thread.sleep(forTimeInterval: 1.5) // Wait for navigation to complete and video to stop
        
        // Verify we're now viewing a photo (not the video)
        // The video should have stopped playing when we swiped away
        XCTAssertTrue(fullScreenView.exists, "Should still be in full screen view")
        
        // Verify we're on a photo by checking if zoomableImage exists
        let photoImageView = app.descendants(matching: .any).matching(identifier: "zoomableImage").firstMatch
        XCTAssertTrue(photoImageView.waitForExistence(timeout: 3), "Should be viewing a photo (zoomableImage should exist)")
        
        // Verify the video player is paused or no longer exists
        // After swiping away, the video player should either be removed from the view hierarchy
        // or if it still exists (in the background), it should be paused
        let videoPlayerAfterSwipe = app.descendants(matching: .any).matching(identifier: "videoPlayer").firstMatch
        if videoPlayerAfterSwipe.exists {
            // If the video player still exists, it must be paused
            XCTAssertEqual(videoPlayerAfterSwipe.value as? String, "paused", "Video player should be paused after swiping away")
        } else {
            // If the video player no longer exists, that's also acceptable
            // (it means the view was properly cleaned up)
        }
    }
}

