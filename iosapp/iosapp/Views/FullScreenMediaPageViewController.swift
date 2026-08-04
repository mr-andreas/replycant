import UIKit
import Combine

/// UIKit container that hosts a UIPageViewController for horizontal media
/// navigation and a UIPanGestureRecognizer for interactive swipe-down
/// dismiss. This replaces the SwiftUI TabView(.page) approach to give
/// precise gesture arbitration between paging, zooming, and dismissal.
final class FullScreenMediaPageViewController: UIViewController {

    private let timelineManager: TimelineManager
    private let initialItemId: String
    private let onDismiss: () -> Void

    private var pageController: UIPageViewController!
    private var currentItemId: String
    private var backgroundView: UIView!
    private var cancellables = Set<AnyCancellable>()
    private var pageScrollView: UIScrollView?

    private let imagePreloader = FullScreenImagePreloader()

    // Dismiss gesture state
    private var dismissPanRecognizer: UIPanGestureRecognizer!

    init(initialItemId: String, timelineManager: TimelineManager, onDismiss: @escaping () -> Void) {
        self.initialItemId = initialItemId
        self.currentItemId = initialItemId
        self.timelineManager = timelineManager
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.accessibilityIdentifier = "fullScreenImage"

        backgroundView = UIView(frame: view.bounds)
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundView.backgroundColor = .black
        view.addSubview(backgroundView)

        pageController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        pageController.dataSource = self
        pageController.delegate = self

        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
        pageScrollView = pageController.view.subviews.compactMap { $0 as? UIScrollView }.first

        if let initialVC = makeChildController(for: currentItemId) {
            pageController.setViewControllers([initialVC], direction: .forward, animated: false)
        }

        dismissPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPanRecognizer.delegate = self
        dismissPanRecognizer.maximumNumberOfTouches = 1
        pageController.view.addGestureRecognizer(dismissPanRecognizer)

        setNeedsStatusBarAppearanceUpdate()
        triggerPreload(for: currentItemId)
        updatePagingEnabledForCurrentChild()
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: - Child factory

    private func makeChildController(for itemId: String) -> UIViewController? {
        guard let item = timelineManager.loadedItems.first(where: { $0.id == itemId }) else {
            return nil
        }
        let isVideo = item.original.spec.mediaType == "video"
        if isVideo {
            let controller = VideoPreviewViewController(item: item, timelineManager: timelineManager, onDismiss: onDismiss)
            wireDetailsStateCallback(for: controller)
            return controller
        } else {
            let controller = ImagePreviewViewController(
                item: item, timelineManager: timelineManager,
                imagePreloader: imagePreloader, onDismiss: onDismiss
            )
            wireDetailsStateCallback(for: controller)
            return controller
        }
    }

    private func itemId(for controller: UIViewController) -> String? {
        if let imageVC = controller as? ImagePreviewViewController {
            return imageVC.item.id
        } else if let videoVC = controller as? VideoPreviewViewController {
            return videoVC.item.id
        }
        return nil
    }

    // MARK: - Page-edge preloading

    private func triggerPreload(for itemId: String) {
        guard let index = timelineManager.loadedItems.firstIndex(where: { $0.id == itemId }) else { return }
        Task { @MainActor in
            if index < 5 {
                await timelineManager.loadOlderPage()
            }
            if index >= max(0, timelineManager.loadedItems.count - 6) {
                await timelineManager.loadNewerPage()
            }
        }

        let radius = CacheSettingsManager.shared.fullScreenPreloadRadius
        if radius > 0,
           let repository = timelineManager.repository,
           let lfsClient = timelineManager.lfsClient {
            imagePreloader.preload(
                around: itemId,
                in: timelineManager.loadedItems,
                radius: radius,
                photoLibrary: timelineManager.photoLibrary,
                repository: repository,
                lfsClient: lfsClient
            )
        }
    }

    // MARK: - Dismiss pan handling

    // Applies dismissal thresholds and pauses active video before closing so
    // swipe-down dismiss matches Done button and page-swipe cleanup behavior.
    @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        let translationY = max(recognizer.translation(in: view).y, 0)
        let velocityY = recognizer.velocity(in: view).y

        switch recognizer.state {
        case .changed:
            let progress = InteractiveDismissDecision.progress(translationY: translationY)
            pageController.view.transform = CGAffineTransform(
                translationX: 0, y: translationY
            ).scaledBy(
                x: 1 - progress * InteractiveDismissDecision.maxScaleReduction,
                y: 1 - progress * InteractiveDismissDecision.maxScaleReduction
            )
            backgroundView.alpha = CGFloat(1.0 - Double(progress) * InteractiveDismissDecision.maxBackgroundFade)

        case .ended, .cancelled, .failed:
            if InteractiveDismissDecision.shouldDismiss(translationY: translationY, velocityY: velocityY) {
                if let videoVC = currentChild as? VideoPreviewViewController {
                    videoVC.pausePlayback()
                }
                onDismiss()
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                    self.pageController.view.transform = .identity
                    self.backgroundView.alpha = 1
                }
            }

        default:
            break
        }
    }

    // MARK: - Current child accessor

    private var currentChild: MediaPreviewControllable? {
        pageController.viewControllers?.first as? MediaPreviewControllable
    }

    private func wireDetailsStateCallback(for controller: MediaPreviewControllable) {
        controller.onDetailsVisibilityChanged = { [weak self] _ in
            self?.updatePagingEnabledForCurrentChild()
        }
    }

    private func updatePagingEnabledForCurrentChild() {
        let detailsVisible = currentChild?.isShowingDetails == true
        pageScrollView?.isScrollEnabled = !detailsVisible
    }
}

// MARK: - UIPageViewControllerDataSource

extension FullScreenMediaPageViewController: UIPageViewControllerDataSource {

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard currentChild?.isShowingDetails != true else { return nil }
        guard let currentId = itemId(for: viewController),
              let index = timelineManager.loadedItems.firstIndex(where: { $0.id == currentId }),
              index > 0 else {
            return nil
        }
        let prevId = timelineManager.loadedItems[index - 1].id
        return makeChildController(for: prevId)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard currentChild?.isShowingDetails != true else { return nil }
        guard let currentId = itemId(for: viewController),
              let index = timelineManager.loadedItems.firstIndex(where: { $0.id == currentId }),
              index < timelineManager.loadedItems.count - 1 else {
            return nil
        }
        let nextId = timelineManager.loadedItems[index + 1].id
        return makeChildController(for: nextId)
    }
}

// MARK: - UIPageViewControllerDelegate

extension FullScreenMediaPageViewController: UIPageViewControllerDelegate {

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed,
              let visibleVC = pageViewController.viewControllers?.first,
              let newId = itemId(for: visibleVC) else {
            return
        }
        currentItemId = newId
        triggerPreload(for: newId)
        updatePagingEnabledForCurrentChild()

        // Pause video on previous controller if it was a video
        for prev in previousViewControllers {
            if let videoVC = prev as? VideoPreviewViewController {
                videoVC.pausePlayback()
            }
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension FullScreenMediaPageViewController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPanRecognizer else { return true }
        if currentChild?.isShowingDetails == true {
            return false
        }
        let velocity = dismissPanRecognizer.velocity(in: view)
        let scale = currentChild?.currentZoomScale ?? 1.0
        let scrollOffset = -(currentChild?.outerScrollView.contentOffset.y ?? 0)
        return InteractiveDismissDecision.shouldBegin(
            velocity: velocity,
            scale: scale,
            scrollOffset: scrollOffset
        )
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPanRecognizer else { return false }
        if currentChild?.isShowingDetails == true {
            return false
        }
        guard let child = currentChild else { return false }
        let outerPan = child.outerScrollView.panGestureRecognizer
        return otherGestureRecognizer === outerPan && child.outerScrollView.contentOffset.y <= 0
    }
}
