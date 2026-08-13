import UIKit
import SwiftUI
import Combine

/// Computes the zoom rect for a double-tap so the image zooms toward
/// the tapped point rather than the center. The rect is sized to fill
/// the scroll view bounds at the target scale, centered on the tap.
struct DoubleTapZoomRect {
    static func zoomRect(for scrollView: UIScrollView, scale: CGFloat, center: CGPoint) -> CGRect {
        let width = scrollView.bounds.width / scale
        let height = scrollView.bounds.height / scale
        let x = center.x - width / 2
        let y = center.y - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Displays one image in full screen with native UIScrollView zoom (pinch
/// anchored at the centroid, double-tap to zoom-to-point), and a panel-style
/// metadata surface that snaps between hidden and shown states.
/// Conforms to MediaPreviewControllable for container gesture arbitration.
final class ImagePreviewViewController: UIViewController, MediaPreviewControllable {

    let item: TimelineItem
    private let timelineManager: TimelineManager
    private let imagePreloader: FullScreenImagePreloader?
    private let onDismiss: () -> Void

    private var zoomScrollView: UIScrollView!
    private var imageView: UIImageView!
    private var detailsPanelView: UIView!
    private var detailsScrollView: UIScrollView!
    private var metadataHostController: UIHostingController<MediaInfoContent>?
    private var spinner: UIActivityIndicatorView!
    private let fallbackScrollView = UIScrollView()
    private var detailsTogglePanRecognizer: UIPanGestureRecognizer!
    // Captures whether the panel was already shown when a toggle pan began so
    // the same recognizer can drive both opening and closing.
    private var panStartShowingDetails = false
    private var didSetupFrames = false
    // True while the user is interactively pulling the shown panel down so
    // scroll-driven progress updates don't fight the snap animation.
    private var isInteractivelyClosing = false

    private var fullResLoader: FullResolutionImageLoader?
    private var cancellables = Set<AnyCancellable>()
    private(set) var isShowingDetails = false {
        didSet {
            guard oldValue != isShowingDetails else { return }
            onDetailsVisibilityChanged?(isShowingDetails)
        }
    }

    var outerScrollView: UIScrollView { detailsScrollView ?? fallbackScrollView }
    var currentZoomScale: CGFloat { zoomScrollView?.zoomScale ?? 1.0 }
    var onDetailsVisibilityChanged: ((Bool) -> Void)?

    init(item: TimelineItem, timelineManager: TimelineManager, imagePreloader: FullScreenImagePreloader? = nil, onDismiss: @escaping () -> Void) {
        self.item = item
        self.timelineManager = timelineManager
        self.imagePreloader = imagePreloader
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        setupZoomScrollView()
        setupImageView()
        setupDetailsPanel()
        setupSpinner()
        setupDoubleTapGesture()
        setupDetailsGestures()

        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutForCurrentBounds()
    }

    // MARK: - Layout setup

    private func setupZoomScrollView() {
        zoomScrollView = UIScrollView()
        zoomScrollView.delegate = self
        zoomScrollView.minimumZoomScale = 1.0
        zoomScrollView.maximumZoomScale = 5.0
        zoomScrollView.showsVerticalScrollIndicator = false
        zoomScrollView.showsHorizontalScrollIndicator = false
        zoomScrollView.bouncesZoom = true
        view.addSubview(zoomScrollView)
    }

    private func setupImageView() {
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = "zoomableImage"
        imageView.accessibilityLabel = item.id
        imageView.accessibilityValue = "normal"
        zoomScrollView.addSubview(imageView)
    }

    private func setupDetailsPanel() {
        detailsPanelView = UIView()
        detailsPanelView.backgroundColor = .systemBackground
        detailsPanelView.layer.cornerRadius = 16
        detailsPanelView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        detailsPanelView.clipsToBounds = true
        view.addSubview(detailsPanelView)

        detailsScrollView = UIScrollView()
        detailsScrollView.alwaysBounceVertical = true
        detailsScrollView.showsVerticalScrollIndicator = true
        detailsScrollView.delegate = self
        detailsPanelView.addSubview(detailsScrollView)

        let hostController = UIHostingController(rootView: MediaInfoContent(item: item))
        hostController.view.backgroundColor = .systemBackground
        addChild(hostController)
        detailsScrollView.addSubview(hostController.view)
        hostController.didMove(toParent: self)
        metadataHostController = hostController
    }

    private func setupSpinner() {
        spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        spinner.startAnimating()
    }

    private func setupDoubleTapGesture() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        zoomScrollView.addGestureRecognizer(doubleTap)
    }

    private func setupDetailsGestures() {
        detailsTogglePanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleDetailsTogglePan(_:)))
        detailsTogglePanRecognizer.delegate = self
        view.addGestureRecognizer(detailsTogglePanRecognizer)
    }

    // MARK: - Content sizing

    // Relays bounds changes into the zoom viewport without resetting an
    // in-progress pinch when SwiftUI issues a no-op layout pass.
    private func layoutForCurrentBounds() {
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let panelHeight = panelHeight(for: viewSize)
        detailsScrollView.frame = CGRect(x: 0, y: 0, width: viewSize.width, height: panelHeight)

        let metadataSize = metadataHostController?.view.systemLayoutSizeFitting(
            CGSize(width: viewSize.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        ) ?? .zero
        metadataHostController?.view.frame = CGRect(
            x: 0,
            y: 0,
            width: viewSize.width,
            height: metadataSize.height
        )
        detailsScrollView.contentSize = CGSize(
            width: viewSize.width,
            height: max(panelHeight, metadataSize.height)
        )

        if !didSetupFrames {
            applyDetailsProgress(isShowingDetails ? 1 : 0)
            didSetupFrames = true
        } else {
            applyDetailsProgress(isShowingDetails ? 1 : 0)
        }
    }

    // Applies a new zoom-scroll-view frame while keeping the user's relative
    // scale and focal point, so rotation and details-panel animation do not
    // snap the photo back to 1x.
    private func setZoomViewport(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        if zoomScrollView.frame == frame {
            return
        }

        let minimumScale = zoomScrollView.minimumZoomScale
        let relativeScale = minimumScale > 0
            ? zoomScrollView.zoomScale / minimumScale
            : 1
        let focal = ZoomableImageLayout.focalPoint(
            contentOffset: zoomScrollView.contentOffset,
            viewportSize: zoomScrollView.bounds.size,
            contentSize: zoomScrollView.contentSize
        )

        zoomScrollView.frame = frame
        applyFittedImageLayout()

        let restoredScale = relativeScale * zoomScrollView.minimumZoomScale
        zoomScrollView.zoomScale = restoredScale
        zoomScrollView.contentOffset = ZoomableImageLayout.contentOffset(
            focalPoint: focal,
            viewportSize: zoomScrollView.bounds.size,
            contentSize: zoomScrollView.contentSize
        )
        recenterZoomedImageIfNeeded()
        updateZoomAccessibilityValue()
    }

    // Fits the image at zoomScale 1 so layout state cannot disagree with
    // the scroll view's recorded scale after a bounds reset.
    private func applyFittedImageLayout() {
        zoomScrollView.zoomScale = 1.0
        guard let image = imageView.image else {
            imageView.frame = zoomScrollView.bounds
            zoomScrollView.contentSize = zoomScrollView.bounds.size
            updateZoomAccessibilityValue()
            return
        }
        let imageFrame = ZoomableImageLayout.fittedFrame(
            imageSize: image.size,
            viewportSize: zoomScrollView.bounds.size
        )
        imageView.frame = imageFrame
        zoomScrollView.contentSize = imageFrame.size
        updateZoomAccessibilityValue()
    }

    // Keeps VoiceOver and UI tests in sync with the actual zoomScale after
    // layout restores a pinch, not only during gesture callbacks.
    private func updateZoomAccessibilityValue() {
        let isZoomed = (zoomScrollView?.zoomScale ?? 1.0) > 1.0
        imageView.accessibilityValue = isZoomed ? "zoomed" : "normal"
    }

    // Reuses the pinch-zoom centering rule so restored scale after a
    // viewport change still sits in the middle when content is smaller
    // than the scroll view.
    private func recenterZoomedImageIfNeeded() {
        guard zoomScrollView != nil else { return }
        scrollViewDidZoom(zoomScrollView)
    }

    // MARK: - Image loading

    private func loadImage() {
        if let cached = imagePreloader?.cachedImage(for: item.id) {
            applyLoadedImage(cached)
            return
        }

        let loader = FullResolutionImageLoader(timelineManager: timelineManager)
        self.fullResLoader = loader
        loader.$image
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let self, let image else { return }
                self.imagePreloader?.store(image, for: self.item.id)
                self.applyLoadedImage(image)
            }
            .store(in: &cancellables)
        loader.loadOriginal(for: item, isVideo: false)
    }

    // Shows the decoded original at 1x fit so the first paint matches the
    // viewport before the user pinches.
    private func applyLoadedImage(_ image: UIImage) {
        imageView.image = image
        spinner.stopAnimating()
        applyFittedImageLayout()
    }

    private func panelHeight(for viewSize: CGSize) -> CGFloat {
        viewSize.height * 0.5
    }

    // Drives image height and panel offset together so opening metadata
    // keeps the current zoom instead of refitting the photo at 1x.
    private func applyDetailsProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let panelHeight = panelHeight(for: viewSize)
        let hiddenZoomFrame = CGRect(x: 0, y: 0, width: viewSize.width, height: viewSize.height)
        let shownZoomFrame = CGRect(x: 0, y: 0, width: viewSize.width, height: viewSize.height - panelHeight)
        setZoomViewport(hiddenZoomFrame.interpolated(to: shownZoomFrame, progress: clamped))

        let hiddenPanelFrame = CGRect(x: 0, y: viewSize.height, width: viewSize.width, height: panelHeight)
        let shownPanelFrame = CGRect(x: 0, y: viewSize.height - panelHeight, width: viewSize.width, height: panelHeight)
        detailsPanelView.frame = hiddenPanelFrame.interpolated(to: shownPanelFrame, progress: clamped)
        detailsScrollView.frame = detailsPanelView.bounds
    }

    private func setDetailsShown(_ shown: Bool, animated: Bool) {
        isShowingDetails = shown
        let targetProgress: CGFloat = shown ? 1 : 0

        let animations = {
            self.applyDetailsProgress(targetProgress)
        }

        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: animations)
        } else {
            animations()
        }

        if !shown {
            detailsScrollView.setContentOffset(.zero, animated: false)
        }
    }

    // MARK: - Actions

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScrollView.zoomScale > 1.0 {
            zoomScrollView.setZoomScale(1.0, animated: true)
        } else {
            let location = recognizer.location(in: imageView)
            let rect = DoubleTapZoomRect.zoomRect(for: zoomScrollView, scale: 2.5, center: location)
            zoomScrollView.zoom(to: rect, animated: true)
        }
    }

    @objc private func handleDetailsTogglePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        let panelHeight = panelHeight(for: view.bounds.size)

        switch recognizer.state {
        case .began:
            panStartShowingDetails = isShowingDetails
        case .changed:
            if panStartShowingDetails {
                // Closing: a downward drag on the image reduces panel progress.
                let progress = min(max(1 - (translation.y / panelHeight), 0), 1)
                applyDetailsProgress(progress)
            } else {
                let progress = min(max(-translation.y / panelHeight, 0), 1)
                applyDetailsProgress(progress)
            }
        case .ended, .cancelled, .failed:
            if panStartShowingDetails {
                let shouldHide = DetailsPanelTransitionDecision.shouldHide(
                    translationY: translation.y,
                    velocityY: velocity.y
                )
                setDetailsShown(!shouldHide, animated: true)
            } else {
                let shouldShow = DetailsPanelTransitionDecision.shouldShow(
                    translationY: translation.y,
                    velocityY: velocity.y
                )
                setDetailsShown(shouldShow, animated: true)
            }
        default:
            break
        }
    }
}

// MARK: - UIScrollViewDelegate (zoom)

extension ImagePreviewViewController: UIScrollViewDelegate {

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        guard scrollView === zoomScrollView else { return nil }
        return imageView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === detailsScrollView, isShowingDetails else { return }
        // While the panel is shown, an overscroll past the top edge means the
        // user is pulling the panel down. Translate the panel (and grow the
        // image) proportionally so closing feels continuous, matching Photos.
        let offsetY = scrollView.contentOffset.y
        guard offsetY < 0 else { return }
        isInteractivelyClosing = true
        let pull = -offsetY
        let panelHeight = panelHeight(for: view.bounds.size)
        let progress = min(max(1 - (pull / panelHeight), 0), 1)
        applyDetailsProgress(progress)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === detailsScrollView, isShowingDetails else { return }
        // Only treat a downward gesture as a close when the content is already
        // at (or pulled past) the top; otherwise it is normal content scrolling.
        guard scrollView.contentOffset.y <= 0 else { return }
        let pull = -scrollView.contentOffset.y
        // scrollView velocity is points/ms with downward drag as negative y;
        // convert to the points/s, finger-down-positive convention used by
        // DetailsPanelTransitionDecision.
        let fingerVelocityY = -velocity.y * 1000
        let shouldHide = DetailsPanelTransitionDecision.shouldHide(
            translationY: max(pull, 0),
            velocityY: fingerVelocityY
        )
        if shouldHide {
            targetContentOffset.pointee = scrollView.contentOffset
            setDetailsShown(false, animated: true)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === detailsScrollView else { return }
        // If the user released a partial pull that didn't cross the close
        // threshold, snap the panel back to fully shown.
        if isInteractivelyClosing && isShowingDetails {
            setDetailsShown(true, animated: true)
        }
        isInteractivelyClosing = false
    }

    // Recenters a zoomed image that no longer fills the viewport so pinch-out
    // and restored scale after rotation do not pin the photo to a corner.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        // Center image if smaller than scroll view bounds
        let boundsSize = scrollView.bounds.size
        var frameToCenter = imageView.frame
        if frameToCenter.size.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
        } else {
            frameToCenter.origin.x = 0
        }
        if frameToCenter.size.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
        } else {
            frameToCenter.origin.y = 0
        }
        imageView.frame = frameToCenter
        updateZoomAccessibilityValue()
    }

    // Snaps accessibility to the final scale so UI tests observe "zoomed"
    // only while the scroll view is actually above 1x.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scrollView === zoomScrollView else { return }
        updateZoomAccessibilityValue()
    }
}

extension ImagePreviewViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)

        if gestureRecognizer === detailsTogglePanRecognizer {
            guard currentZoomScale <= 1.001 else { return false }
            let verticalDominant = abs(velocity.y) > abs(velocity.x) * DetailsPanelTransitionDecision.axisVelocityRatio
            guard verticalDominant else { return false }

            if isShowingDetails {
                // Closing the panel with a downward swipe on the image itself.
                // The panel's own scroll view handles swipe-down within the panel,
                // so only begin when the touch is on the image area above it.
                guard velocity.y > 0 else { return false }
                let location = gestureRecognizer.location(in: view)
                return !detailsPanelView.frame.contains(location)
            } else {
                // Opening the panel with an upward swipe.
                return velocity.y < 0
            }
        }

        return true
    }
}

private extension CGRect {
    func interpolated(to target: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + ((target.origin.x - origin.x) * progress),
            y: origin.y + ((target.origin.y - origin.y) * progress),
            width: size.width + ((target.size.width - size.width) * progress),
            height: size.height + ((target.size.height - size.height) * progress)
        )
    }
}

#if DEBUG
// Exposes zoom layout internals so unit tests can assert scale/frame
// consistency without putting the controller in a window.
extension ImagePreviewViewController {
    // Installs a decoded image through the production load path so tests
    // exercise the same 1x fit as a successful LFS fetch.
    func testingApplyImage(_ image: UIImage) {
        applyLoadedImage(image)
    }

    var testingZoomScale: CGFloat { zoomScrollView.zoomScale }
    var testingImageFrame: CGRect { imageView.frame }
    var testingContentSize: CGSize { zoomScrollView.contentSize }
    var testingContentOffset: CGPoint { zoomScrollView.contentOffset }

    // Applies a pinch scale without animation so tests can start from a
    // known zoomed state before a layout pass.
    func testingSetZoomScale(_ scale: CGFloat) {
        zoomScrollView.setZoomScale(scale, animated: false)
        recenterZoomedImageIfNeeded()
        updateZoomAccessibilityValue()
    }

    // Pans the zoomed content so rotation tests can check a non-centered
    // focal point rather than the default midpoint.
    func testingSetContentOffset(_ offset: CGPoint) {
        zoomScrollView.contentOffset = offset
    }

    // Drives the zoom-preserving viewport funnel directly so tests can
    // change bounds without waiting for a full view layout cycle.
    func testingSetViewportFrame(_ frame: CGRect) {
        setZoomViewport(frame)
    }
}
#endif
