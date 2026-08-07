import Foundation
import Testing
import AVFoundation
import UIKit
@testable import iosapp

// Verifies fullscreen media loading prefers local Photo Library sources when enabled.
@MainActor
@Suite("FullResolutionImageLoader Local Media Tests", .serialized)
struct FullResolutionImageLoaderLocalMediaTests {
    // Binds the manager to a private notification center. Reset and endpoint
    // broadcasts are process-wide and clear the loaded region, so a manager on
    // the default center can be wiped mid-test by an unrelated suite.
    private func makeIsolatedManager(photoLibrary: PhotoLibraryProviding) -> TimelineManager {
        TimelineManager(photoLibrary: photoLibrary, notificationCenter: NotificationCenter())
    }

    // Creates a minimal timeline item fixture with an optional local Photos identifier.
    private func makeItem(
        id: String = "item-1",
        localID: String? = "local-1",
        mediaType: String = "photo",
        mimeType: String = "image/jpeg",
        duration: Double? = nil
    ) -> TimelineItem {
        let manifest = OriginalManifest(
            id: id,
            localID: localID,
            sha256: "sha-\(id)",
            path: "file-\(id)",
            filesize: 1024,
            name: id,
            deviceSpace: "device-space-1",
            mediaType: mediaType,
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: duration,
            mimeType: mimeType,
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

    // Produces deterministic JPEG bytes so decode assertions are stable.
    private func makeJPEGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    // Creates a temporary mp4 file URL for AVURLAsset based local playback tests.
    private func makeTempVideoURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-video-\(UUID().uuidString).mp4"
        )
        try Data([0, 1, 2, 3]).write(to: url, options: .atomic)
        return url
    }

    // Waits for asynchronous loader tasks to publish image/player/error state.
    private func waitForLoaderSettled(_ loader: FullResolutionImageLoader, maxIterations: Int = 120) async {
        for _ in 0..<maxIterations {
            if loader.image != nil || loader.player != nil || loader.errorMessage != nil {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // Confirms local full-resolution images are used before LFS when enabled.
    @Test func testPhotoUsesLocalOriginalWhenEnabled() async {
        CacheSettingsManager.shared.localThumbnailsEnabled = true
        let localID = "photo-local-id"
        let mockLibrary = MockPhotoLibraryProvider()
        mockLibrary.isAuthorized = true
        mockLibrary.localOriginalImageData[localID] = makeJPEGData()
        let manager = makeIsolatedManager(photoLibrary: mockLibrary)
        let loader = FullResolutionImageLoader(timelineManager: manager)

        loader.loadOriginal(for: makeItem(localID: localID), isVideo: false)
        await waitForLoaderSettled(loader)

        #expect(loader.image != nil)
        #expect(loader.errorMessage == nil)
    }

    // Confirms photo loading falls through to existing remote path when local lookup misses.
    @Test func testPhotoFallsBackWhenLocalOriginalMissing() async {
        CacheSettingsManager.shared.localThumbnailsEnabled = true
        let localID = "photo-local-id"
        let mockLibrary = MockPhotoLibraryProvider()
        mockLibrary.isAuthorized = true
        let manager = makeIsolatedManager(photoLibrary: mockLibrary)
        let loader = FullResolutionImageLoader(timelineManager: manager)

        loader.loadOriginal(for: makeItem(localID: localID), isVideo: false)
        await waitForLoaderSettled(loader)

        #expect(loader.image == nil)
        #expect(loader.errorMessage != nil)
    }

    // Confirms local full-resolution video assets are used before server streaming when enabled.
    @Test func testVideoUsesLocalAssetWhenEnabled() async throws {
        CacheSettingsManager.shared.localThumbnailsEnabled = true
        let localID = "video-local-id"
        let mockLibrary = MockPhotoLibraryProvider()
        mockLibrary.isAuthorized = true
        let videoURL = try makeTempVideoURL()
        mockLibrary.localVideoAssetURLs[localID] = videoURL
        let manager = makeIsolatedManager(photoLibrary: mockLibrary)
        let loader = FullResolutionImageLoader(timelineManager: manager)

        loader.loadOriginal(
            for: makeItem(localID: localID, mediaType: "video", mimeType: "video/mp4", duration: 3),
            isVideo: true
        )
        await waitForLoaderSettled(loader)

        #expect(loader.player != nil)
        #expect(loader.errorMessage == nil)
    }

    // Confirms the development toggle still disables local-first paths for performance testing.
    @Test func testVideoSkipsLocalWhenToggleDisabled() async throws {
        CacheSettingsManager.shared.localThumbnailsEnabled = false
        let localID = "video-local-id"
        let mockLibrary = MockPhotoLibraryProvider()
        mockLibrary.isAuthorized = true
        let videoURL = try makeTempVideoURL()
        mockLibrary.localVideoAssetURLs[localID] = videoURL
        let manager = makeIsolatedManager(photoLibrary: mockLibrary)
        let loader = FullResolutionImageLoader(timelineManager: manager)

        loader.loadOriginal(
            for: makeItem(localID: localID, mediaType: "video", mimeType: "video/mp4", duration: 3),
            isVideo: true
        )
        await waitForLoaderSettled(loader)

        #expect(loader.player == nil)
        #expect(loader.errorMessage != nil)
    }
}
