import AVFoundation
import Testing
import UIKit
@testable import iosapp

// Verifies fullscreen video buffering keeps timeline visual continuity by
// showing and then clearing the poster thumbnail at the right lifecycle points.
@MainActor
@Suite("VideoPreviewViewController Poster Tests", .serialized)
struct VideoPreviewViewControllerPosterTests {
    // Binds the manager to a private notification center. Reset and endpoint
    // broadcasts are process-wide and clear the loaded region, so a manager on
    // the default center can be wiped mid-test by an unrelated suite.
    private func makeIsolatedManager() -> TimelineManager {
        TimelineManager(notificationCenter: NotificationCenter())
    }

    // Builds a video timeline item fixture so tests can isolate poster behavior
    // from repository/network setup.
    private func makeVideoItem(id: String = "video-1") -> TimelineItem {
        let manifest = OriginalManifest(
            id: id,
            localID: nil,
            sha256: "sha-\(id)",
            path: "VID_0001.MP4",
            filesize: 1024,
            name: id,
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

    // Produces deterministic image data so poster assertions do not depend on
    // external assets or simulator state.
    private func makeTestImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }

    // Ensures fullscreen launch immediately reuses the timeline thumbnail from
    // memory cache so users never see an empty black frame first.
    @Test func loadsPosterFromTimelineCacheOnViewLoad() {
        let item = makeVideoItem()
        let manager = makeIsolatedManager()
        let expectedImage = makeTestImage()
        manager.cacheImage(expectedImage, for: item.id)
        let controller = VideoPreviewViewController(
            item: item,
            timelineManager: manager,
            onDismiss: {}
        )

        controller.loadViewIfNeeded()

        #expect(controller.testingPosterImage != nil)
    }

    // Ensures a spinner is visible during loading so users know the video is
    // buffering even when the poster thumbnail is already displayed.
    @Test func spinnerIsActiveOnViewLoad() {
        let item = makeVideoItem()
        let manager = makeIsolatedManager()
        manager.cacheImage(makeTestImage(), for: item.id)
        let controller = VideoPreviewViewController(
            item: item,
            timelineManager: manager,
            onDismiss: {}
        )

        controller.loadViewIfNeeded()

        #expect(controller.testingHasSpinner)
    }

    // Ensures poster is removed when embedding a player with no current item,
    // since there is nothing to wait for readiness on.
    @Test func removesPosterWhenEmbeddingPlayerWithoutCurrentItem() {
        let item = makeVideoItem()
        let manager = makeIsolatedManager()
        manager.cacheImage(makeTestImage(), for: item.id)
        let controller = VideoPreviewViewController(
            item: item,
            timelineManager: manager,
            onDismiss: {}
        )
        controller.loadViewIfNeeded()
        #expect(controller.testingPosterImage != nil)

        controller.testingEmbedVideoPlayer(AVPlayer())

        #expect(controller.testingPosterImage == nil)
    }

    // Ensures controller disappearance pauses active playback so swipe-dismiss
    // cannot leave audio playing after the fullscreen UI is gone.
    @Test func viewWillDisappearPausesActivePlayer() {
        let controller = VideoPreviewViewController(
            item: makeVideoItem(),
            timelineManager: makeIsolatedManager(),
            onDismiss: {}
        )
        let player = AVPlayer()
        controller.testingInjectPlayerForLifecycle(player)
        #expect(controller.testingPausePlaybackCount == 0)

        controller.viewWillDisappear(false)

        #expect(controller.testingPausePlaybackCount == 1)
    }

    // Ensures returning to a cached video page restarts playback from the
    // beginning instead of resuming the prior paused position.
    @Test func restartPlaybackSeeksToStartAndRequestsPlay() {
        let controller = VideoPreviewViewController(
            item: makeVideoItem(),
            timelineManager: makeIsolatedManager(),
            onDismiss: {}
        )
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
        let player = AVPlayer(playerItem: item)
        controller.testingInjectPlayerForLifecycle(player)
        #expect(!controller.testingRestartRequestedSeekToStart)
        #expect(!controller.testingRestartRequestedPlay)

        controller.testingRestartPlayback()

        #expect(controller.testingRestartRequestedSeekToStart)
        #expect(controller.testingRestartRequestedPlay)
    }

    // Ensures second appearance (after paging away and back) triggers restart
    // while first appearance keeps initial launch path unchanged.
    @Test func viewWillAppearRestartsPlaybackOnlyAfterFirstAppearance() {
        let controller = VideoPreviewViewController(
            item: makeVideoItem(),
            timelineManager: makeIsolatedManager(),
            onDismiss: {}
        )
        #expect(controller.testingRestartPlaybackCount == 0)
        #expect(!controller.testingHasAppeared)

        controller.viewWillAppear(false)
        #expect(controller.testingHasAppeared)
        #expect(controller.testingRestartPlaybackCount == 0)

        controller.viewWillAppear(false)
        #expect(controller.testingRestartPlaybackCount == 1)
    }

    // Ensures replay buffering re-shows poster and spinner so swipe-back feels
    // consistent with initial fullscreen loading feedback.
    @Test func restartPlaybackReshowsPosterAndSpinner() {
        let item = makeVideoItem()
        let manager = makeIsolatedManager()
        manager.cacheImage(makeTestImage(), for: item.id)
        let controller = VideoPreviewViewController(
            item: item,
            timelineManager: manager,
            onDismiss: {}
        )
        let player = AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")))

        controller.loadViewIfNeeded()
        controller.testingEmbedVideoPlayer(AVPlayer())
        #expect(controller.testingPosterImage == nil)
        #expect(!controller.testingHasSpinner)
        controller.testingInjectPlayerForLifecycle(player)

        controller.testingRestartPlayback()

        #expect(controller.testingPosterImage != nil)
        #expect(controller.testingHasSpinner)
    }
}
