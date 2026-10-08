import Combine
import Testing
import UIKit
@testable import iosapp

// Stops fullscreen video from starting a full-quality stream on mobile
// data until the user confirms, because there is no transcode to shrink it.
@MainActor
@Suite("Video Cellular Playback Gate Tests", .serialized)
struct VideoCellularPlaybackGateTests {
    private func makeIsolatedManager() -> TimelineManager {
        TimelineManager(notificationCenter: NotificationCenter())
    }

    private func makeVideoItem(filesize: Int64 = 1024) -> TimelineItem {
        let manifest = OriginalManifest(
            id: "video-1",
            localID: nil,
            sha256: "sha-video-1",
            path: "VID_0001.MP4",
            filesize: filesize,
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

    private func makeController(metered: Bool, filesize: Int64 = 1024) -> VideoPreviewViewController {
        VideoPreviewViewController(
            item: makeVideoItem(filesize: filesize),
            timelineManager: makeIsolatedManager(),
            onDismiss: {},
            networkCost: StubNetworkCost(isMetered: metered)
        )
    }

    // A remote video on mobile data must not open a stream until the user
    // accepts the warning. The play button is the only affordance.
    @Test func meteredRemoteVideoWaitsForConfirmation() async {
        let controller = makeController(metered: true)
        controller.loadViewIfNeeded()

        for _ in 0..<50 where !controller.testingHasCellularPlayButton {
            await Task.yield()
        }

        #expect(controller.testingHasCellularPlayButton)
        #expect(!controller.testingDidStartVideoLoad)
    }

    // Confirming the warning is what starts the stream.
    @Test func confirmingMeteredPlaybackStartsTheLoad() async {
        let controller = makeController(metered: true)
        controller.loadViewIfNeeded()
        for _ in 0..<50 where !controller.testingHasCellularPlayButton {
            await Task.yield()
        }

        controller.testingConfirmCellularPlayback()

        #expect(controller.testingDidStartVideoLoad)
        #expect(!controller.testingHasCellularPlayButton)
    }

    // Wi-Fi keeps today's autoplay and never shows the mobile-data button.
    @Test func unmeteredVideoStartsImmediately() {
        let controller = makeController(metered: false)
        controller.loadViewIfNeeded()

        #expect(controller.testingDidStartVideoLoad)
        #expect(!controller.testingHasCellularPlayButton)
    }

    // The warning has to name the original file size so the user can judge
    // the transfer before there is a smaller transcode.
    @Test func warningMessageIncludesFormattedFileSize() {
        let bytes: Int64 = 1_200_000_000
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: bytes)

        let message = VideoPreviewViewController.cellularWarningMessage(filesize: bytes)

        #expect(message.contains(size))
        #expect(message.contains("transcoding"))
    }
}

// Supplies a fixed network cost so fullscreen tests do not depend on the
// simulator's real path.
final class StubNetworkCost: NetworkCostProviding {
    let isMetered: Bool
    var isMeteredPublisher: AnyPublisher<Bool, Never> {
        Just(isMetered).eraseToAnyPublisher()
    }

    init(isMetered: Bool) {
        self.isMetered = isMetered
    }
}
