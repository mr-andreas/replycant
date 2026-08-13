import CoreGraphics

/// Pure zoom-viewport geometry so ImagePreviewViewController can preserve
/// scale and focal point across bounds changes without UIKit side effects.
enum ZoomableImageLayout {

    // Sizes the image to aspect-fit the viewport so 1x zoom matches the
    // on-screen photo without stretching.
    static func fittedFrame(imageSize: CGSize, viewportSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return CGRect(origin: .zero, size: viewportSize)
        }

        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewportSize.width / viewportSize.height
        if imageAspect > viewAspect {
            let height = viewportSize.width / imageAspect
            return CGRect(
                x: 0,
                y: (viewportSize.height - height) / 2,
                width: viewportSize.width,
                height: height
            )
        }
        let width = viewportSize.height * imageAspect
        return CGRect(
            x: (viewportSize.width - width) / 2,
            y: 0,
            width: width,
            height: viewportSize.height
        )
    }

    // Records the content point at the viewport centre in unit coordinates
    // so a later bounds change can restore the same focal point.
    static func focalPoint(
        contentOffset: CGPoint,
        viewportSize: CGSize,
        contentSize: CGSize
    ) -> CGPoint {
        let x = contentSize.width > 0
            ? (contentOffset.x + viewportSize.width / 2) / contentSize.width
            : 0.5
        let y = contentSize.height > 0
            ? (contentOffset.y + viewportSize.height / 2) / contentSize.height
            : 0.5
        return CGPoint(x: x, y: y)
    }

    // Converts a unit focal point back into a content offset, clamping to
    // the scrollable range and using zero when the image is smaller than
    // the viewport so centering stays on the image-view origin.
    static func contentOffset(
        focalPoint: CGPoint,
        viewportSize: CGSize,
        contentSize: CGSize
    ) -> CGPoint {
        let maxX = max(contentSize.width - viewportSize.width, 0)
        let maxY = max(contentSize.height - viewportSize.height, 0)
        let unclampedX = focalPoint.x * contentSize.width - viewportSize.width / 2
        let unclampedY = focalPoint.y * contentSize.height - viewportSize.height / 2
        return CGPoint(
            x: min(max(unclampedX, 0), maxX),
            y: min(max(unclampedY, 0), maxY)
        )
    }
}
