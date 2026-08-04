import Foundation
import Testing
import Photos
import UIKit
@testable import iosapp

// Verifies local Photo Library thumbnail lookup behavior used by timeline image loading.
@MainActor
@Suite("ImageLoader Local Thumbnail Tests", .serialized)
struct ImageLoaderLocalThumbnailTests {
    // Clears persisted toggle state so each test controls local-thumbnail behavior explicitly.
    private func clearLocalThumbnailSetting() {
        UserDefaults.standard.removeObject(forKey: "localThumbnailsEnabled")
    }

    // Creates a minimal original manifest fixture with configurable local Photos identifier.
    private func makeOriginal(localID: String?) -> OriginalManifest {
        OriginalManifest(
            id: "original-1",
            localID: localID,
            sha256: "deadbeef",
            path: "IMG_0001.JPG",
            filesize: 1024,
            name: "original-1",
            deviceSpace: "device-space-1",
            mediaType: "photo",
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(),
            takenAt: Date(),
            clientCTime: nil,
            guessedTakenAt: Date()
        )
    }

    // Produces a deterministic UIImage payload so local-thumbnail resolution can be asserted.
    private func makeTestImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    // Ensures local lookup is used when the toggle is enabled and the original has a local Photos identifier.
    @Test func testLoadLocalThumbnailWhenEnabledAndAvailable() async {
        clearLocalThumbnailSetting()
        CacheSettingsManager.shared.localThumbnailsEnabled = true

        let localID = "photo-local-id"
        let mockLibrary = MockPhotoLibraryProvider(localThumbnails: [localID: makeTestImage()])
        let manager = TimelineManager(photoLibrary: mockLibrary)
        let item = TimelineItem(original: makeOriginal(localID: localID))
        let loader = ImageLoader(item: item, timelineManager: manager)

        let image = await loader.loadLocalThumbnailIfAvailable()

        #expect(image != nil)
        #expect(mockLibrary.localThumbnailRequests.count == 1)
        #expect(mockLibrary.localThumbnailRequests.first?.localID == localID)
        #expect(mockLibrary.localThumbnailRequests.first?.size == CGSize(width: 225, height: 225))
    }

    // Ensures disabled setting bypasses local lookup so the caller can proceed with the LFS fallback path.
    @Test func testLoadLocalThumbnailBypassesWhenDisabled() async {
        clearLocalThumbnailSetting()
        CacheSettingsManager.shared.localThumbnailsEnabled = false

        let localID = "photo-local-id"
        let mockLibrary = MockPhotoLibraryProvider(localThumbnails: [localID: makeTestImage()])
        let manager = TimelineManager(photoLibrary: mockLibrary)
        let item = TimelineItem(original: makeOriginal(localID: localID))
        let loader = ImageLoader(item: item, timelineManager: manager)

        let image = await loader.loadLocalThumbnailIfAvailable()

        #expect(image == nil)
        #expect(mockLibrary.localThumbnailRequests.isEmpty)
    }

    // Ensures missing local thumbnails return nil so image loading can fall back to the existing remote flow.
    @Test func testLoadLocalThumbnailReturnsNilWhenMissing() async {
        clearLocalThumbnailSetting()
        CacheSettingsManager.shared.localThumbnailsEnabled = true

        let localID = "photo-local-id"
        let mockLibrary = MockPhotoLibraryProvider()
        let manager = TimelineManager(photoLibrary: mockLibrary)
        let item = TimelineItem(original: makeOriginal(localID: localID))
        let loader = ImageLoader(item: item, timelineManager: manager)

        let image = await loader.loadLocalThumbnailIfAvailable()

        #expect(image == nil)
        #expect(mockLibrary.localThumbnailRequests.count == 1)
        #expect(mockLibrary.localThumbnailRequests.first?.localID == localID)
    }

    // Ensures timeline local-thumbnail lookup never touches Photos APIs before upload permission has been granted.
    @Test func testLoadLocalThumbnailBypassesWhenUnauthorized() async {
        clearLocalThumbnailSetting()
        CacheSettingsManager.shared.localThumbnailsEnabled = true

        let localID = "photo-local-id"
        let mockLibrary = MockPhotoLibraryProvider(localThumbnails: [localID: makeTestImage()])
        mockLibrary.isAuthorized = false
        let manager = TimelineManager(photoLibrary: mockLibrary)
        let item = TimelineItem(original: makeOriginal(localID: localID))
        let loader = ImageLoader(item: item, timelineManager: manager)

        let image = await loader.loadLocalThumbnailIfAvailable()

        #expect(image == nil)
        #expect(mockLibrary.localThumbnailRequests.isEmpty)
    }

    // Ensures sparse-page reconfigure keeps an in-flight or completed loader for the same item.
    @Test func testShouldPreserveLoaderAcrossSameItemReconfigure() {
        #expect(
            TimelineThumbnailLoadPolicy.shouldPreserveLoader(
                isSameItem: true,
                hasImage: false,
                isLoading: true
            )
        )
        #expect(
            TimelineThumbnailLoadPolicy.shouldPreserveLoader(
                isSameItem: true,
                hasImage: true,
                isLoading: false
            )
        )
        #expect(
            !TimelineThumbnailLoadPolicy.shouldPreserveLoader(
                isSameItem: true,
                hasImage: false,
                isLoading: false
            )
        )
        #expect(
            !TimelineThumbnailLoadPolicy.shouldPreserveLoader(
                isSameItem: false,
                hasImage: false,
                isLoading: true
            )
        )
    }
}
