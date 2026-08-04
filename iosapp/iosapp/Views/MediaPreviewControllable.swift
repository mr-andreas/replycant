import UIKit

/// Shared interface that image and video child controllers expose so the
/// container page controller can arbitrate dismiss and paging gestures
/// against zoom/scroll state without knowing the concrete child type.
protocol MediaPreviewControllable: UIViewController {
    var outerScrollView: UIScrollView { get }
    var currentZoomScale: CGFloat { get }
    var isShowingDetails: Bool { get }
    var onDetailsVisibilityChanged: ((Bool) -> Void)? { get set }
}
