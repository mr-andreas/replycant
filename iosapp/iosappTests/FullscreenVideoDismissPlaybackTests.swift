import AVFoundation
import Testing
import UIKit
@testable import iosapp

// Guards the dismiss path that used to leave audio running when a video was
// reached by paging rather than opened directly from the timeline grid.
@MainActor
@Suite("Fullscreen Video Dismiss Playback Tests", .serialized)
struct FullscreenVideoDismissPlaybackTests {
    // Binds the manager to a private notification center. Reset and endpoint
    // broadcasts are process-wide and clear the loaded region, so a manager on
    // the default center can be wiped mid-test by an unrelated suite.
    private func makeIsolatedManager() -> TimelineManager {
        TimelineManager(notificationCenter: NotificationCenter())
    }

    // Builds photo or video fixtures so paging tests can seed an image-then-
    // video region without a repository.
    private func makeItem(id: String, mediaType: String) -> TimelineItem {
        let manifest = OriginalManifest(
            id: id,
            localID: nil,
            sha256: "sha-\(id)",
            path: "\(id).dat",
            filesize: 1024,
            name: id,
            deviceSpace: "device-space-1",
            mediaType: mediaType,
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: mediaType == "video" ? 12.0 : nil,
            mimeType: mediaType == "video" ? "video/mp4" : "image/jpeg",
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

    // Produces an AVPlayer with an item so detach assertions can observe
    // currentItem going nil after teardown.
    private func makePlayer() -> AVPlayer {
        AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")))
    }

    // Builds a direct-play loader so tests can wire the seek-resume gate
    // without contacting a server.
    private func makeDirectPlayLoader() throws -> DirectPlayResourceLoader {
        let url = try #require(URL(string: "https://example.com/decryptd/objects/abc"))
        return DirectPlayResourceLoader(
            httpURL: url,
            headers: [:],
            mimeType: "video/mp4",
            clientIdentity: nil,
            pinnedCA: nil
        )
    }

    // Ensures stopPlayback detaches the player item so a later play()
    // cannot produce audio. AVPlayer.play() still sets rate to 1.0 with
    // no item; the detached currentItem is the invariant that proves
    // nothing can decode.
    @Test func stopPlaybackDetachesPlayerItem() {
        let controller = VideoPreviewViewController(
            item: makeItem(id: "video-1", mediaType: "video"),
            timelineManager: makeIsolatedManager(),
            onDismiss: {}
        )
        let player = makePlayer()
        controller.testingInjectPlayerForLifecycle(player)
        #expect(player.currentItem != nil)

        controller.stopPlayback()

        #expect(player.rate == 0)
        #expect(player.currentItem == nil)
        player.play()
        #expect(player.currentItem == nil)
    }

    // Reproduces the direct-play seek-resume race: in-flight started and
    // ready callbacks captured before teardown must not restart audio.
    @Test func lateSeekResumeCannotRestartAfterTeardown() async throws {
        let loader = FullResolutionImageLoader(timelineManager: makeIsolatedManager())
        let player = makePlayer()
        let directPlayLoader = try makeDirectPlayLoader()
        loader.testingInstallDirectPlayResumeGate(
            player: player,
            loader: directPlayLoader,
            armResume: true
        )
        let pendingStarted = try #require(directPlayLoader.onSeekRangeReplacementStarted)
        let pendingReady = try #require(directPlayLoader.onSeekRangeReplacementReady)

        loader.teardownPlayback()

        #expect(directPlayLoader.onSeekRangeReplacementReady == nil)
        #expect(directPlayLoader.onSeekRangeReplacementStarted == nil)
        #expect(player.currentItem == nil)

        pendingReady()
        await Task.yield()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(player.rate == 0)
        #expect(player.currentItem == nil)

        pendingStarted()
        pendingReady()
        await Task.yield()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(player.rate == 0)
        #expect(player.currentItem == nil)
    }

    // Covers the reported bug: paging from an image onto a video, then
    // dismissing, must tear that paged-to video down.
    @Test func dismissStopsVideoReachedByPaging() throws {
        let image = makeItem(id: "image-1", mediaType: "photo")
        let video = makeItem(id: "video-1", mediaType: "video")
        let manager = makeIsolatedManager()
        manager.seedLoadedRegionForTesting(offset: 0, items: [image, video], totalCount: 2)

        let pageController = FullScreenMediaPageViewController(
            initialItemId: image.id,
            timelineManager: manager,
            onDismiss: {}
        )
        pageController.loadViewIfNeeded()
        let current = try #require(pageController.testingPageViewController.viewControllers?.first)
        let next = pageController.pageViewController(
            pageController.testingPageViewController,
            viewControllerAfter: current
        )
        let videoController = try #require(next as? VideoPreviewViewController)
        let player = makePlayer()
        videoController.testingInjectPlayerForLifecycle(player)

        pageController.viewWillDisappear(false)

        #expect(player.rate == 0)
        #expect(player.currentItem == nil)
    }

    // Guards the already-working direct-open path so dismissal still stops
    // playback when the first page is the video itself.
    @Test func dismissStopsVideoOpenedDirectly() throws {
        let video = makeItem(id: "video-1", mediaType: "video")
        let manager = makeIsolatedManager()
        manager.seedLoadedRegionForTesting(offset: 0, items: [video], totalCount: 1)

        let pageController = FullScreenMediaPageViewController(
            initialItemId: video.id,
            timelineManager: manager,
            onDismiss: {}
        )
        pageController.loadViewIfNeeded()
        let videoController = try #require(
            pageController.testingPageViewController.viewControllers?.first
                as? VideoPreviewViewController
        )
        let player = makePlayer()
        videoController.testingInjectPlayerForLifecycle(player)

        pageController.viewWillDisappear(false)

        #expect(player.rate == 0)
        #expect(player.currentItem == nil)
    }
}
