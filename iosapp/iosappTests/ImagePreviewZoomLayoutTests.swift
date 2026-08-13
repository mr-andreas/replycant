import Testing
import UIKit
@testable import iosapp

// Verifies zoom geometry and ImagePreviewViewController layout so a
// commit-driven layout pass cannot desync zoomScale from the fitted image.
@MainActor
@Suite("ImagePreview zoom layout", .serialized)
struct ImagePreviewZoomLayoutTests {

    private let pixelAccuracy: CGFloat = 1.0
    private let unitAccuracy: CGFloat = 0.02
    private let scaleAccuracy: CGFloat = 0.05

    // Binds the manager to a private notification center so process-wide
    // reset broadcasts cannot wipe fixtures mid-suite.
    private func makeIsolatedManager() -> TimelineManager {
        TimelineManager(notificationCenter: NotificationCenter())
    }

    // Builds a photo timeline item so preview tests do not need a repository.
    private func makePhotoItem(id: String = "photo-1") -> TimelineItem {
        let takenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = OriginalManifest(
            id: id,
            localID: nil,
            sha256: "sha-\(id)",
            path: "IMG_0001.JPG",
            filesize: 1024,
            name: id,
            deviceSpace: "device-space-1",
            mediaType: "photo",
            width: 400,
            height: 400,
            modifiedAt: nil,
            duration: nil,
            mimeType: "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: takenAt,
            takenAt: takenAt,
            guessedTakenAt: takenAt
        )
        return TimelineItem(original: manifest)
    }

    // Produces a square bitmap so fitted-frame math stays deterministic.
    private func makeTestImage(size: CGSize = CGSize(width: 400, height: 400)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // Compares layout scalars with a caller-chosen tolerance so pixel
    // frames and unit focal points can share one helper.
    private func expectEqual(_ a: CGFloat, _ b: CGFloat, accuracy: CGFloat) {
        #expect(abs(a - b) < accuracy)
    }

    private func expectEqual(_ a: CGSize, _ b: CGSize, accuracy: CGFloat) {
        expectEqual(a.width, b.width, accuracy: accuracy)
        expectEqual(a.height, b.height, accuracy: accuracy)
    }

    private func expectEqual(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat) {
        expectEqual(a.x, b.x, accuracy: accuracy)
        expectEqual(a.y, b.y, accuracy: accuracy)
    }

    private func expectEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat) {
        expectEqual(a.origin, b.origin, accuracy: accuracy)
        expectEqual(a.size, b.size, accuracy: accuracy)
    }

    // Hosts the preview at a known size so layout tests do not depend on
    // the simulator window.
    private func makePreview(
        bounds: CGRect = CGRect(x: 0, y: 0, width: 393, height: 852),
        imageSize: CGSize = CGSize(width: 400, height: 400)
    ) -> (ImagePreviewViewController, UIImage) {
        let controller = ImagePreviewViewController(
            item: makePhotoItem(),
            timelineManager: makeIsolatedManager(),
            onDismiss: {}
        )
        controller.view.frame = bounds
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        let image = makeTestImage(size: imageSize)
        controller.testingApplyImage(image)
        controller.view.layoutIfNeeded()
        return (controller, image)
    }

    // MARK: - Pure geometry

    // Wide images must letterbox vertically so 1x zoom fills the viewport width.
    @Test func fittedFrame_wideImage_fitsWidthAndCentersVertically() {
        let frame = ZoomableImageLayout.fittedFrame(
            imageSize: CGSize(width: 2000, height: 1000),
            viewportSize: CGSize(width: 400, height: 800)
        )
        expectEqual(frame, CGRect(x: 0, y: 300, width: 400, height: 200), accuracy: pixelAccuracy)
    }

    // Tall images must pillarbox horizontally so 1x zoom fills the viewport height.
    @Test func fittedFrame_tallImage_fitsHeightAndCentersHorizontally() {
        let frame = ZoomableImageLayout.fittedFrame(
            imageSize: CGSize(width: 1000, height: 4000),
            viewportSize: CGSize(width: 400, height: 800)
        )
        expectEqual(frame, CGRect(x: 100, y: 0, width: 200, height: 800), accuracy: pixelAccuracy)
    }

    // Focal-point conversion must round-trip so rotation can restore the
    // same content point after the viewport size changes.
    @Test func focalPoint_roundTripsThroughContentOffset() {
        let viewport = CGSize(width: 400, height: 800)
        let content = CGSize(width: 1200, height: 2400)
        let offset = CGPoint(x: 100, y: 200)

        let focal = ZoomableImageLayout.focalPoint(
            contentOffset: offset,
            viewportSize: viewport,
            contentSize: content
        )
        let restored = ZoomableImageLayout.contentOffset(
            focalPoint: focal,
            viewportSize: viewport,
            contentSize: content
        )
        expectEqual(restored, offset, accuracy: pixelAccuracy)
    }

    // Offsets past the scrollable range must clamp so restored zoom cannot
    // bounce the image out of the viewport.
    @Test func contentOffset_clampsToScrollableRange() {
        let viewport = CGSize(width: 400, height: 800)
        let content = CGSize(width: 1000, height: 2000)

        let minOffset = ZoomableImageLayout.contentOffset(
            focalPoint: .zero,
            viewportSize: viewport,
            contentSize: content
        )
        expectEqual(minOffset, .zero, accuracy: pixelAccuracy)

        let maxOffset = ZoomableImageLayout.contentOffset(
            focalPoint: CGPoint(x: 1, y: 1),
            viewportSize: viewport,
            contentSize: content
        )
        expectEqual(maxOffset, CGPoint(x: 600, y: 1200), accuracy: pixelAccuracy)
    }

    // Undersized content must sit at offset zero so centering stays on the
    // image view origin rather than a negative content offset.
    @Test func contentOffset_centresUndersizedContentAtZeroOffset() {
        let offset = ZoomableImageLayout.contentOffset(
            focalPoint: CGPoint(x: 0.5, y: 0.5),
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 200, height: 300)
        )
        expectEqual(offset, .zero, accuracy: pixelAccuracy)
    }

    // MARK: - View controller regression

    // A no-op layout pass (the commit-driven SwiftUI update) must not
    // rewrite a zoomed image back to its 1x fitted frame.
    @Test func unchangedBoundsLayout_preservesZoomedState() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let (controller, _) = makePreview(bounds: bounds)
        controller.testingSetZoomScale(3)
        controller.view.layoutIfNeeded()

        let zoomBefore = controller.testingZoomScale
        let frameBefore = controller.testingImageFrame
        let contentBefore = controller.testingContentSize

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.viewDidLayoutSubviews()

        expectEqual(controller.testingZoomScale, zoomBefore, accuracy: scaleAccuracy)
        expectEqual(controller.testingImageFrame, frameBefore, accuracy: pixelAccuracy)
        expectEqual(controller.testingContentSize, contentBefore, accuracy: pixelAccuracy)
        #expect(controller.testingZoomScale > 1.5)
    }

    // After any relayout, returning to minimum zoom must fill the viewport
    // rather than shrinking the already-fitted image by the leftover scale.
    @Test func afterRelayout_minimumZoomMatchesFittedSize() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let (controller, image) = makePreview(bounds: bounds)
        controller.testingSetZoomScale(3)
        controller.viewDidLayoutSubviews()
        controller.testingSetZoomScale(1)

        let expected = ZoomableImageLayout.fittedFrame(
            imageSize: image.size,
            viewportSize: bounds.size
        )
        expectEqual(controller.testingContentSize, expected.size, accuracy: pixelAccuracy)
        expectEqual(controller.testingZoomScale, 1, accuracy: scaleAccuracy)
    }

    // Device rotation must keep the relative scale and the content point
    // that was centered in the viewport, matching Photos.app behavior.
    @Test func rotation_preservesRelativeScaleAndFocalPoint() {
        let portrait = CGRect(x: 0, y: 0, width: 393, height: 852)
        let landscape = CGRect(x: 0, y: 0, width: 852, height: 393)
        let (controller, _) = makePreview(bounds: portrait)
        controller.testingSetZoomScale(3)
        let safeFocal = CGPoint(x: 0.42, y: 0.55)
        controller.testingSetContentOffset(
            ZoomableImageLayout.contentOffset(
                focalPoint: safeFocal,
                viewportSize: portrait.size,
                contentSize: controller.testingContentSize
            )
        )

        let focalBefore = ZoomableImageLayout.focalPoint(
            contentOffset: controller.testingContentOffset,
            viewportSize: portrait.size,
            contentSize: controller.testingContentSize
        )
        let scaleBefore = controller.testingZoomScale

        controller.view.frame = landscape
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        expectEqual(controller.testingZoomScale, scaleBefore, accuracy: scaleAccuracy)
        let focalAfter = ZoomableImageLayout.focalPoint(
            contentOffset: controller.testingContentOffset,
            viewportSize: landscape.size,
            contentSize: controller.testingContentSize
        )
        expectEqual(focalAfter, focalBefore, accuracy: unitAccuracy)
    }
}
