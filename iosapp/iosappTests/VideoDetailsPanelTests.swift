import Testing
import UIKit
@testable import iosapp

// A fullscreen video has to open the same metadata sheet as a photo.
// These tests drive the pan directly so a regression is caught without
// a window or a finger.
@MainActor
@Suite("Video Details Panel Tests", .serialized)
struct VideoDetailsPanelTests {
    private let viewSize = CGSize(width: 390, height: 844)

    private func makeIsolatedManager() -> TimelineManager {
        TimelineManager(notificationCenter: NotificationCenter())
    }

    // A video item with a duration so the sheet has the same metadata
    // a real clip would show. The pan tests do not read the text.
    private func makeVideoItem() -> TimelineItem {
        let manifest = OriginalManifest(
            id: "video-1",
            localID: nil,
            sha256: "sha-video-1",
            path: "VID_0001.MP4",
            filesize: 1024,
            name: "video-1",
            deviceSpace: "device-space-1",
            mediaType: "video",
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: 12.0,
            mimeType: "video/mp4",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(),
            takenAt: Date(),
            clientCTime: nil,
            guessedTakenAt: Date()
        )
        return TimelineItem(original: manifest)
    }

    // Gives the controller a real size. A zero frame would make the
    // half-height sheet math look like a successful resize.
    private func makeController() -> VideoPreviewViewController {
        let controller = VideoPreviewViewController(
            item: makeVideoItem(),
            timelineManager: makeIsolatedManager(),
            onDismiss: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: viewSize)
        controller.view.layoutIfNeeded()
        return controller
    }

    // Runs the pan to completion with animations off so the sheet frame
    // is the committed one, not an in-flight animation.
    private func drivePan(
        _ controller: VideoPreviewViewController,
        translationY: CGFloat,
        velocityY: CGFloat
    ) {
        UIView.setAnimationsEnabled(false)
        controller.testingDriveDetailsPan(state: .began, translationY: 0, velocityY: velocityY)
        controller.testingDriveDetailsPan(
            state: .changed,
            translationY: translationY,
            velocityY: velocityY
        )
        controller.testingDriveDetailsPan(
            state: .ended,
            translationY: translationY,
            velocityY: velocityY
        )
        UIView.setAnimationsEnabled(true)
    }

    // An upward drag past the photo threshold opens the sheet, shrinks
    // the video to the top half, and tells the pager to stop paging.
    @Test func upwardDragPastThresholdShowsDetails() {
        let controller = makeController()
        var visibility: [Bool] = []
        controller.onDetailsVisibilityChanged = { visibility.append($0) }

        drivePan(controller, translationY: -80, velocityY: -50)

        #expect(controller.isShowingDetails)
        #expect(controller.testingMediaContainerFrame.height == viewSize.height / 2)
        #expect(visibility == [true])
    }

    // A short slow upward nudge must not open the sheet. The same
    // threshold keeps photo details from appearing on an accidental flick.
    @Test func shortSlowUpwardDragLeavesDetailsHidden() {
        let controller = makeController()

        drivePan(controller, translationY: -20, velocityY: -100)

        #expect(!controller.isShowingDetails)
        #expect(controller.testingMediaContainerFrame.height == viewSize.height)
    }

    // A downward drag past the hide threshold puts the video back to
    // full frame so swipe-down dismiss works again.
    @Test func downwardDragPastThresholdHidesDetails() {
        let controller = makeController()
        var visibility: [Bool] = []
        controller.onDetailsVisibilityChanged = { visibility.append($0) }
        drivePan(controller, translationY: -80, velocityY: -50)

        drivePan(controller, translationY: 70, velocityY: 40)

        #expect(!controller.isShowingDetails)
        #expect(controller.testingMediaContainerFrame.height == viewSize.height)
        #expect(visibility == [true, false])
    }

    // Horizontal movement belongs to paging and the scrubber. Only a
    // vertical-dominant upward pan may start the sheet.
    @Test func horizontalVelocityDoesNotBeginDetailsPan() {
        let controller = makeController()

        #expect(
            !controller.testingDetailsPanShouldBegin(
                velocity: CGPoint(x: 400, y: 100),
                touchInsidePanel: false
            )
        )
        #expect(
            controller.testingDetailsPanShouldBegin(
                velocity: CGPoint(x: 0, y: -500),
                touchInsidePanel: false
            )
        )
    }
}
