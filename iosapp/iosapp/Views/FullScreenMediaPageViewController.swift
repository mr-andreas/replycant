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
    // Weakly tracks every video page this session created so dismiss can
    // stop playback even if that page is not the visible child.
    private let vendedVideoControllers = NSHashTable<VideoPreviewViewController>.weakObjects()

    // Share and save sit on the pager, not on each page, so photos and
    // videos use one control. The generation drops a finished export
    // that the user already cancelled or paged away from.
    private var exportBar: UIStackView!
    private var shareButton: UIButton!
    private var saveButton: UIButton!
    private var shareImage: UIImage?
    private var saveImage: UIImage?
    private var exportSpinner: UIActivityIndicatorView?
    private var progressTrack: CAShapeLayer?
    private var progressStroke: CAShapeLayer?
    private var exportTask: Task<Void, Never>?
    private var exportGeneration = 0
    private var activeExportButton: UIButton?
    private var exportCanCancel = false
    // Set while a share sheet or alert is covering the viewer, so that
    // cover is not treated as the user leaving the photo.
    private var isCoveringViewer = false

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

        setupExportButtons()
        setNeedsStatusBarAppearanceUpdate()
        triggerPreload(for: currentItemId)
        updatePagingEnabledForCurrentChild()
    }

    override var prefersStatusBarHidden: Bool { true }

    // Keeps the download ring circular after rotation. The path is in
    // the button's bounds, which are zero until the first layout.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateProgressRingPath()
    }

    // Stops every video this pager has vended, including ones created during
    // a page swipe that never became the visible child, so dismiss cannot
    // leave audio running in the background.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A share sheet or alert covers this controller without the
        // user leaving the photo. Stopping playback or the export then
        // would cancel the thing they just asked for.
        guard presentedViewController == nil, !isCoveringViewer else { return }
        stopAllVideoPlayback()
        cancelExport()
    }

    // MARK: - Child factory

    // Builds the image or video page for one timeline item and tracks video
    // controllers so dismiss can stop playback even if that page was only
    // created as a paging neighbor.
    private func makeChildController(for itemId: String) -> UIViewController? {
        guard let item = timelineManager.loadedItems.first(where: { $0.id == itemId }) else {
            return nil
        }
        let isVideo = item.original.spec.mediaType == "video"
        if isVideo {
            let controller = VideoPreviewViewController(item: item, timelineManager: timelineManager, onDismiss: onDismiss)
            vendedVideoControllers.add(controller)
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

    // Applies dismissal thresholds and stops every vended video before closing
    // so swipe-down cannot leave audio running after the cover is gone.
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
            exportBar.alpha = backgroundView.alpha

        case .ended, .cancelled, .failed:
            if InteractiveDismissDecision.shouldDismiss(translationY: translationY, velocityY: velocityY) {
                stopAllVideoPlayback()
                cancelExport()
                onDismiss()
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                    self.pageController.view.transform = .identity
                    self.backgroundView.alpha = 1
                    self.exportBar.alpha = 1
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
        exportBar?.isHidden = detailsVisible
    }

    // Tears down every tracked video so paging-created controllers are not
    // left playing after the fullscreen cover dismisses.
    private func stopAllVideoPlayback() {
        for videoVC in vendedVideoControllers.allObjects {
            videoVC.stopPlayback()
        }
    }

    // MARK: - Share and save

    // Which button started the export, so a finished file is handed to
    // the share sheet or the camera roll and not the other one.
    private enum ExportDestination {
        case share
        case save
    }

    // Pins share and save to the top corner. They stay above the page
    // so a video's playback controls, which sit at the bottom, do not
    // cover them.
    private func setupExportButtons() {
        shareButton = makeExportButton(
            imageName: "square.and.arrow.up",
            identifier: "shareMediaButton",
            label: "Share",
            action: #selector(shareTapped)
        )
        saveButton = makeExportButton(
            imageName: "square.and.arrow.down",
            identifier: "saveMediaButton",
            label: "Save to Photos",
            action: #selector(saveTapped)
        )
        shareImage = shareButton.image(for: .normal)
        saveImage = saveButton.image(for: .normal)

        exportBar = UIStackView(arrangedSubviews: [shareButton, saveButton])
        exportBar.axis = .horizontal
        exportBar.spacing = 8
        exportBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(exportBar)
        NSLayoutConstraint.activate([
            exportBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            exportBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    // Builds one corner button. The dark circle keeps a white symbol
    // visible on a light photo.
    private func makeExportButton(
        imageName: String,
        identifier: String,
        label: String,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .custom)
        let image = UIImage(
            systemName: imageName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        )
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 22
        button.clipsToBounds = true
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    // Starts a share, or cancels a video download already running on
    // this button.
    @objc private func shareTapped() {
        handleExportTap(.share)
    }

    // Starts a camera-roll save, or cancels a video download already
    // running on this button.
    @objc private func saveTapped() {
        handleExportTap(.save)
    }

    // A video download can be cancelled by tapping the same button.
    // A photo export is short, so a second tap does nothing until it
    // finishes.
    private func handleExportTap(_ destination: ExportDestination) {
        let button = destination == .share ? shareButton : saveButton
        if exportCanCancel, exportTask != nil, button === activeExportButton {
            cancelExport()
            return
        }
        guard exportTask == nil else { return }
        if destination == .save,
           let item = timelineManager.loadedItems.first(where: { $0.id == currentItemId }),
           MediaExport.isAlreadyInPhotos(
               item: item,
               photoLibrary: timelineManager.photoLibrary,
               savedMedia: .shared
           ) {
            presentAlreadyInPhotos(isVideo: item.original.spec.mediaType == "video")
            return
        }
        startExport(destination)
    }

    // Exports the item on screen, then either opens the share sheet
    // or writes the camera roll. A newer tap or a page change drops
    // the result so it cannot land on the wrong item.
    private func startExport(_ destination: ExportDestination) {
        guard let item = timelineManager.loadedItems.first(where: { $0.id == currentItemId }) else {
            return
        }
        let button = destination == .share ? shareButton! : saveButton!
        let isVideo = item.original.spec.mediaType == "video"
        activeExportButton = button
        exportCanCancel = isVideo
        showExportSpinner(on: button)
        setExportButtonsEnabled(active: button, enabled: false)
        if isVideo {
            button.accessibilityLabel = "Downloading video. Tap to cancel."
        } else {
            button.accessibilityLabel = destination == .share ? "Sharing" : "Saving"
        }

        exportGeneration += 1
        let generation = exportGeneration
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var exported: URL?
            do {
                let url = try await MediaExport.exportOriginal(
                    item: item,
                    timelineManager: self.timelineManager
                ) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, generation == self.exportGeneration else { return }
                        self.showDownloadProgress(fraction, on: button)
                    }
                }
                exported = url
                guard generation == self.exportGeneration else {
                    self.removeExportFolder(url)
                    return
                }
                switch destination {
                case .share:
                    self.finishExportChrome()
                    self.exportTask = nil
                    self.presentShare(url: url, source: button)
                case .save:
                    let createdID = try await MediaExport.saveToPhotos(fileURL: url, isVideo: isVideo)
                    if let createdID {
                        SavedMediaStore.shared.record(localIdentifier: createdID, forItemID: item.id)
                    }
                    self.removeExportFolder(url)
                    guard generation == self.exportGeneration else { return }
                    self.showSavedCheckmark(generation: generation)
                }
            } catch {
                if Self.isExportCancellation(error) {
                    return
                }
                if let exported {
                    self.removeExportFolder(exported)
                }
                guard generation == self.exportGeneration else { return }
                self.finishExportChrome()
                self.exportTask = nil
                self.presentExportFailure(error)
            }
        }
    }

    // URLSession reports a cancelled download as URLError, not
    // CancellationError. Both mean the user left or tapped the ring,
    // so neither should become an error alert.
    private static func isExportCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    // Stops an in-flight download and puts the buttons back. A share
    // sheet that is already up keeps its file until it closes.
    private func cancelExport() {
        exportGeneration += 1
        exportTask?.cancel()
        exportTask = nil
        exportCanCancel = false
        finishExportChrome()
    }

    // Shows a spinner for exports that finish quickly. Server video
    // downloads replace it with a ring once bytes arrive.
    private func showExportSpinner(on button: UIButton) {
        removeProgressRing()
        button.setImage(nil, for: .normal)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        spinner.startAnimating()
        exportSpinner = spinner
    }

    // Replaces the spinner once bytes are moving, so a long video is
    // not an indeterminate wait. Tapping the ring cancels the task.
    private func showDownloadProgress(_ fraction: Double, on button: UIButton) {
        exportSpinner?.removeFromSuperview()
        exportSpinner = nil
        button.setImage(nil, for: .normal)
        exportCanCancel = true
        if progressStroke == nil {
            let track = CAShapeLayer()
            track.fillColor = UIColor.clear.cgColor
            track.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
            track.lineWidth = 2.5
            track.lineCap = .round
            let stroke = CAShapeLayer()
            stroke.fillColor = UIColor.clear.cgColor
            stroke.strokeColor = UIColor.white.cgColor
            stroke.lineWidth = 2.5
            stroke.lineCap = .round
            stroke.strokeEnd = 0
            button.layer.addSublayer(track)
            button.layer.addSublayer(stroke)
            progressTrack = track
            progressStroke = stroke
            updateProgressRingPath()
        }
        let clamped = min(1, max(0, fraction))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressStroke?.strokeEnd = clamped
        CATransaction.commit()
        let percent = Int((clamped * 100).rounded())
        button.accessibilityLabel = "Downloading video, \(percent) percent. Tap to cancel."
    }

    // Rebuilds the ring in the button's current bounds so rotation
    // does not leave a clipped or offset stroke.
    private func updateProgressRingPath() {
        guard let button = activeExportButton, let track = progressTrack, let stroke = progressStroke else {
            return
        }
        let lineWidth = track.lineWidth
        let radius = min(button.bounds.width, button.bounds.height) / 2 - lineWidth
        guard radius > 0 else { return }
        let path = UIBezierPath(
            arcCenter: CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: 3 * .pi / 2,
            clockwise: true
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.path = path.cgPath
        stroke.path = path.cgPath
        CATransaction.commit()
    }

    // Restores both buttons after an export ends, is cancelled, or
    // fails, so the next item is not stuck on a spinner.
    private func finishExportChrome() {
        exportSpinner?.removeFromSuperview()
        exportSpinner = nil
        removeProgressRing()
        shareButton.setImage(shareImage, for: .normal)
        saveButton.setImage(saveImage, for: .normal)
        shareButton.accessibilityLabel = "Share"
        saveButton.accessibilityLabel = "Save to Photos"
        shareButton.isEnabled = true
        saveButton.isEnabled = true
        activeExportButton = nil
        exportCanCancel = false
    }

    // Drops the ring layers so a later photo export does not draw a
    // leftover stroke under its spinner.
    private func removeProgressRing() {
        progressTrack?.removeFromSuperlayer()
        progressStroke?.removeFromSuperlayer()
        progressTrack = nil
        progressStroke = nil
    }

    // Leaves the tapped button enabled when it is the cancel control
    // for a video download, and disables the other one.
    private func setExportButtonsEnabled(active: UIButton, enabled: Bool) {
        shareButton.isEnabled = enabled || shareButton === active
        saveButton.isEnabled = enabled || saveButton === active
    }

    // Confirms the camera-roll write without leaving the viewer.
    private func showSavedCheckmark(generation: Int) {
        finishExportChrome()
        exportTask = nil
        let checkmark = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        )
        saveButton.setImage(checkmark, for: .normal)
        saveButton.accessibilityLabel = "Saved to Photos"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard generation == self.exportGeneration else { return }
            self.saveButton.setImage(self.saveImage, for: .normal)
            self.saveButton.accessibilityLabel = "Save to Photos"
        }
    }

    // Presents the system share sheet for the exported file and
    // deletes that file once the sheet closes.
    private func presentShare(url: URL, source: UIButton) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        }
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.isCoveringViewer = false
            self?.removeExportFolder(url)
        }
        isCoveringViewer = true
        present(controller, animated: true)
    }

    // A second copy is not what the user asked for. The alert is the
    // whole result, so no download or camera-roll write starts.
    private func presentAlreadyInPhotos(isVideo: Bool) {
        let kind = isVideo ? "video" : "photo"
        let alert = UIAlertController(
            title: "Already in Photos",
            message: "This \(kind) is already in your photo library.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.isCoveringViewer = false
        })
        isCoveringViewer = true
        present(alert, animated: true)
    }

    // Explains a failed export. Denied Photos access offers Settings
    // because the system will not ask again.
    private func presentExportFailure(_ error: Error) {
        let alert = UIAlertController(
            title: "Couldn't export",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.isCoveringViewer = false
        })
        if let exportError = error as? MediaExport.MediaExportError,
           case .photoLibraryDenied = exportError {
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { [weak self] _ in
                self?.isCoveringViewer = false
                guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settings)
            })
        }
        isCoveringViewer = true
        present(alert, animated: true)
    }

    // Removes the per-export temp folder, not just the file, so a
    // cancelled or finished export leaves nothing behind.
    private func removeExportFolder(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
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
        if newId != currentItemId {
            cancelExport()
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

#if DEBUG
// Exposes the hosted pager so unit tests can vend neighbor pages the same
// way a user swipe would, without presenting the fullscreen cover.
extension FullScreenMediaPageViewController {
    // Exposes the pager so dismiss tests can vend neighbor video pages.
    var testingPageViewController: UIPageViewController { pageController }
}
#endif
