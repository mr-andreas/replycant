import UIKit
import SwiftUI
import AVKit
import Combine
import GitDB

/// Displays one video in full screen within the UIPageViewController.
/// Hosts the AVPlayer via SwiftUI VideoPlayer for playback controls while
/// conforming to MediaPreviewControllable so the container can arbitrate
/// dismiss gestures against this child. An upward swipe opens the same
/// metadata sheet as a photo, so paging and dismiss stay locked while
/// the sheet is visible and playback keeps running above it.
final class VideoPreviewViewController: UIViewController, MediaPreviewControllable {

    let item: TimelineItem
    private let timelineManager: TimelineManager
    private let onDismiss: () -> Void
    private let networkCost: NetworkCostProviding

    // The sheet's scroll view is what the pager consults before a
    // swipe-down dismiss. A fallback covers the moment before the sheet
    // exists so the property never traps.
    private let fallbackScrollView = UIScrollView()
    private var detailsScrollView: UIScrollView!
    var outerScrollView: UIScrollView { detailsScrollView ?? fallbackScrollView }
    var currentZoomScale: CGFloat { 1.0 }
    // The pager reads this to disable paging and dismiss while metadata
    // is up. Playback is left running; only the chrome around it changes.
    private(set) var isShowingDetails = false {
        didSet {
            guard oldValue != isShowingDetails else { return }
            onDetailsVisibilityChanged?(isShowingDetails)
        }
    }
    var onDetailsVisibilityChanged: ((Bool) -> Void)?

    private var mediaContainer: UIView!
    private var detailsPanelView: UIView!
    private var metadataHostController: UIHostingController<MediaInfoContent>?
    private var detailsTogglePanRecognizer: UIPanGestureRecognizer!
    // Captures whether the sheet was already open when the pan began so
    // one recognizer can both open and close it.
    private var panStartShowingDetails = false
    // True while a pull on the open sheet is moving it, so the scroll
    // view's end callback doesn't snap it shut and open in the same drag.
    private var isInteractivelyClosing = false

    private var fullResLoader: FullResolutionImageLoader?
    private var cancellables = Set<AnyCancellable>()
    private var hostController: UIHostingController<AnyView>?
    private var posterImageView: UIImageView?
    private var posterSpinner: UIActivityIndicatorView?
    private var cellularPlayButton: UIButton?
    private var posterLoadTask: Task<Void, Never>?
    private var playerReadyObservation: NSKeyValueObservation?
    private var playerRateObservation: NSKeyValueObservation?
    // False while this page is only a neighbor pulled in by a drag.
    // A stream that becomes ready then must not call play().
    private var playbackAllowed = false
    private var didRequestPlayback = false
#if DEBUG
    private(set) var testingPausePlaybackCallCount = 0
    private(set) var testingRestartPlaybackInvocationCount = 0
    private(set) var testingDidRequestSeekToStart = false
    private(set) var testingDidRequestPlayAfterRestart = false
    private(set) var didStartVideoLoad = false
#endif

    init(
        item: TimelineItem,
        timelineManager: TimelineManager,
        onDismiss: @escaping () -> Void,
        networkCost: NetworkCostProviding = NetworkCostMonitor.shared
    ) {
        self.item = item
        self.timelineManager = timelineManager
        self.onDismiss = onDismiss
        self.networkCost = networkCost
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Shows the poster without opening the stream. A sideways drag builds
    // this page before it is visible, and starting playback here would
    // play a video that is still off screen.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupMediaContainer()
        setupDetailsPanel()
        setupDetailsGestures()
        setupPosterView()
        loadPosterImage()
    }

    // Reapplies the committed sheet position after rotation. Interactive
    // drags set frames themselves; this only restores the open or closed
    // resting place so a bounds change cannot leave the sheet halfway.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDetailsForCurrentBounds()
    }

    // Stops playback when this page leaves, including a drag that never
    // settles, so a neighbor cannot keep playing after the finger lifts.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pausePlayback()
    }

    // The page is the one on screen. Cellular still waits for confirmation
    // before any bytes move. A later call, after the user swipes back,
    // replays from the start instead of the paused position.
    func beginSettledPlayback() {
        playbackAllowed = true
        if let player = fullResLoader?.player {
            if player.currentItem != nil {
                restartPlayback()
            } else {
                player.play()
            }
            return
        }
        guard !didRequestPlayback else { return }
        didRequestPlayback = true
        if networkCost.isMetered {
            resolveLocalOrHoldForConfirmation()
        } else {
            loadVideo()
        }
    }

    // A cancelled swipe paused the page that stayed up. Continue it
    // instead of seeking back to the start.
    func resumeSettledPlayback() {
        guard didRequestPlayback else { return }
        playbackAllowed = true
        fullResLoader?.player?.play()
    }

    // Centralizes pause behavior so dismissal and a half-finished swipe
    // share one cleanup step. A stream that becomes ready afterwards
    // stays paused, because this page is no longer the one on screen.
    func pausePlayback() {
#if DEBUG
        testingPausePlaybackCallCount += 1
#endif
        playbackAllowed = false
        fullResLoader?.player?.pause()
    }

    // Tears the player down so dismiss cannot leave audio running after a
    // late direct-play seek-resume callback. Page swipes keep pausePlayback()
    // so swipe-back can still restart the same player.
    func stopPlayback() {
        pausePlayback()
        fullResLoader?.teardownPlayback()
    }

    // Replays this video from the start when paging returns to a cached video
    // controller so navigation feels consistent with first-open autoplay.
    func restartPlayback() {
#if DEBUG
        testingRestartPlaybackInvocationCount += 1
        testingDidRequestSeekToStart = false
        testingDidRequestPlayAfterRestart = false
#endif
        guard let player = fullResLoader?.player, player.currentItem != nil else {
            return
        }
        reshowPosterIfNeeded()
        observePlaybackStart(player)
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
#if DEBUG
        testingDidRequestSeekToStart = true
#endif
        player.play()
#if DEBUG
        testingDidRequestPlayAfterRestart = true
#endif
    }

    // MARK: - Video loading

    // Loads the fullscreen video stream while preserving existing dismissal
    // and error behavior from the previous playback implementation.
    private func loadVideo() {
#if DEBUG
        didStartVideoLoad = true
#endif
        let loader = FullResolutionImageLoader(timelineManager: timelineManager)
        self.fullResLoader = loader
        observeLoader(loader)
        loader.loadOriginal(for: item, isVideo: true)
    }

    // Plays a Photos copy immediately on mobile data, and otherwise leaves
    // the poster up until the user accepts the full-quality transfer.
    private func resolveLocalOrHoldForConfirmation() {
        let loader = FullResolutionImageLoader(timelineManager: timelineManager)
        self.fullResLoader = loader
        observeLoader(loader)
        Task { [weak self] in
            guard let self else { return }
            let foundLocal = await loader.loadLocalVideoIfAvailable(for: self.item)
            guard !foundLocal else { return }
            self.showCellularPlayButton()
        }
    }

    // Subscribes once per loader so a later confirmed stream replaces the
    // unused local-only probe without embedding a stale player.
    private func observeLoader(_ loader: FullResolutionImageLoader) {
        cancellables.removeAll()

        loader.$player
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .first()
            .sink { [weak self] player in
                guard let self else { return }
                self.embedVideoPlayer(player: player)
            }
            .store(in: &cancellables)

        loader.$errorMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .first()
            .sink { [weak self] error in
                guard let self else { return }
                self.showError(error)
            }
            .store(in: &cancellables)
    }

    // Keeps the poster and hides the spinner so a remote video on mobile
    // data looks paused until the user chooses to spend the data.
    private func showCellularPlayButton() {
        posterSpinner?.stopAnimating()
        guard cellularPlayButton == nil else { return }

        let button = UIButton(type: .system)
        let symbol = UIImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        button.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: symbol), for: .normal)
        button.tintColor = .white
        button.accessibilityIdentifier = "cellularPlayButton"
        button.accessibilityLabel = "Play"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cellularPlayButtonTapped), for: .touchUpInside)
        mediaContainer.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: mediaContainer.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: mediaContainer.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 88),
            button.heightAnchor.constraint(equalToConstant: 88),
        ])
        cellularPlayButton = button
        bringPlaybackChromeToFront()
    }

    // Asks before streaming the original, because there is no transcode
    // to shrink the video on a metered network.
    @objc private func cellularPlayButtonTapped() {
        presentCellularDataWarning()
    }

    // Names the original file size so the user can judge the transfer.
    static func cellularWarningMessage(filesize: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: filesize)
        return "Videos stream in their original quality because transcoding isn't available yet. Playing this video may use up to \(size) of data."
    }

    // Confirms the full-quality transfer before AVPlayer opens the stream.
    private func presentCellularDataWarning() {
        let alert = UIAlertController(
            title: "Play over mobile data?",
            message: Self.cellularWarningMessage(filesize: item.original.spec.filesize),
            preferredStyle: .alert
        )
        // The button sits where the alert text is. Hiding it keeps the
        // warning readable, and cancel puts it back.
        cellularPlayButton?.isHidden = true
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.cellularPlayButton?.isHidden = false
        })
        alert.addAction(UIAlertAction(title: "Play", style: .default) { [weak self] _ in
            self?.confirmCellularPlayback()
        })
        present(alert, animated: true)
    }

    // Starts the stream only after the user accepts the data warning.
    private func confirmCellularPlayback() {
        cellularPlayButton?.removeFromSuperview()
        cellularPlayButton = nil
        posterSpinner?.startAnimating()
        loadVideo()
    }

    // Hosts AVPlayer content and removes the poster only after AVFoundation
    // reports the first frame can be displayed.
    private func embedVideoPlayer(player: AVPlayer) {
        let videoView = VideoPreviewContent(
            player: player
        )
        let host = UIHostingController(rootView: AnyView(videoView))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = mediaContainer.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mediaContainer.addSubview(host.view)
        host.didMove(toParent: self)
        hostController = host
        bringPlaybackChromeToFront()

        observePlayerReadiness(player)
        if playbackAllowed {
            player.play()
        }
    }

    // Shows the same thumbnail users saw in the timeline so fullscreen video
    // avoids an abrupt black frame during initial buffering. A centered spinner
    // signals that playback is loading.
    private func setupPosterView() {
        let imageView = UIImageView(frame: mediaContainer.bounds)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = false
        imageView.accessibilityIdentifier = "videoPosterImage"
        mediaContainer.addSubview(imageView)
        posterImageView = imageView

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        mediaContainer.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: mediaContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: mediaContainer.centerYAnchor),
        ])
        spinner.startAnimating()
        posterSpinner = spinner
    }

    // Prefers timeline-memory thumbnails and falls back to disk/LFS so poster
    // display works for both warm and cold fullscreen launches.
    private func loadPosterImage() {
        if let cachedImage = timelineManager.getCachedImage(for: item.id) {
            posterImageView?.image = cachedImage
            return
        }

        guard let thumbnailSet = findMatchingThumbnail(
            for: item.original,
            in: timelineManager.thumbnailMap
        ),
        let thumbnail = pickBestThumbnailEntry(from: thumbnailSet, targetWidth: 225),
        let repository = timelineManager.repository,
        let lfsClient = timelineManager.lfsClient else {
            return
        }

        let deviceSpace = thumbnailSet.metadata.deviceSpace
        let thumbnailPath = "encryptionspaces/\(deviceSpace)/binary/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(thumbnail.name))"
        posterLoadTask?.cancel()
        let itemID = item.id
        posterLoadTask = Task { [weak self] in
            do {
                let imageData = try await ImageDiskCacheManager.shared.loadImageData(
                    kind: .thumbnail,
                    priority: .fullscreenCurrent,
                    itemId: itemID,
                    lfsPath: thumbnailPath,
                    repository: repository,
                    lfsClient: lfsClient
                )
                guard !Task.isCancelled, let image = UIImage(data: imageData) else {
                    return
                }
                await MainActor.run {
                    self?.posterImageView?.image = image
                }
            } catch {
                logDebug("Poster thumbnail load skipped: \(error.localizedDescription)", context: "FullScreen")
            }
        }
    }

    // Waits for the player item to report readiness before removing the
    // poster. The poster is layered above the VideoPlayer so it stays
    // visible during buffering; once `readyToPlay` fires the player has
    // enough data to begin rendering and the poster can safely go away.
    // We avoid `timeControlStatus == .playing` because direct-play's seek
    // range replacement callbacks cycle pause/play and prevent the player
    // from ever settling into `.playing` during initial load.
    private func observePlayerReadiness(_ player: AVPlayer) {
        guard let currentItem = player.currentItem else {
            removePosterIfPresent()
            return
        }
        playerReadyObservation = currentItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                self?.removePosterIfPresent()
            }
        }
    }

    // Keeps replay buffering feedback visible until playback actually resumes
    // so swipe-back sessions do not flash paused frames without loading affordance.
    private func observePlaybackStart(_ player: AVPlayer) {
        playerRateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            guard player.rate > 0 else { return }
            DispatchQueue.main.async {
                self?.removePosterIfPresent()
            }
        }
    }

    // Recreates poster UI when revisiting a cached video page so seek-induced
    // buffering still surfaces familiar loading feedback.
    private func reshowPosterIfNeeded() {
        if posterImageView == nil {
            let imageView = UIImageView(frame: mediaContainer.bounds)
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black
            imageView.isUserInteractionEnabled = false
            imageView.accessibilityIdentifier = "videoPosterImage"
            imageView.image = timelineManager.getCachedImage(for: item.id)
            mediaContainer.addSubview(imageView)
            posterImageView = imageView
        }
        if posterSpinner == nil {
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.color = .white
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.hidesWhenStopped = true
            mediaContainer.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: mediaContainer.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: mediaContainer.centerYAnchor),
            ])
            spinner.startAnimating()
            posterSpinner = spinner
        }
        bringPlaybackChromeToFront()
    }

    // Removes the poster and spinner once playback is visually ready so
    // controls stay responsive and transition artifacts remain hidden.
    private func removePosterIfPresent() {
        posterSpinner?.stopAnimating()
        posterSpinner?.removeFromSuperview()
        posterSpinner = nil
        posterImageView?.removeFromSuperview()
        posterImageView = nil
        playerReadyObservation = nil
        playerRateObservation = nil
    }

    // Presents playback failures with consistent fullscreen messaging when
    // stream startup cannot complete.
    private func showError(_ error: String) {
        let errorView = VideoErrorContent(error: error)
        let host = UIHostingController(rootView: AnyView(errorView))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = mediaContainer.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mediaContainer.addSubview(host.view)
        host.didMove(toParent: self)
    }

    // Holds the poster, player, spinner, and play button so the sheet can
    // shrink them together. They used to be pinned to the page, which left
    // no room for metadata without covering the video.
    private func setupMediaContainer() {
        let container = UIView(frame: view.bounds)
        container.backgroundColor = .black
        container.clipsToBounds = true
        view.addSubview(container)
        mediaContainer = container
    }

    // The same metadata photo details show, including duration, so a video
    // does not need a second info layout.
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

        let metadataHost = UIHostingController(rootView: MediaInfoContent(item: item))
        metadataHost.view.backgroundColor = .systemBackground
        addChild(metadataHost)
        detailsScrollView.addSubview(metadataHost.view)
        metadataHost.didMove(toParent: self)
        metadataHostController = metadataHost
    }

    // Swipe up is how photos reveal details. The recognizer lives on the
    // page so it can see the video and the sheet, and claim a vertical
    // pan before VideoPlayer treats it as its own.
    private func setupDetailsGestures() {
        detailsTogglePanRecognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleDetailsTogglePan(_:))
        )
        detailsTogglePanRecognizer.delegate = self
        view.addGestureRecognizer(detailsTogglePanRecognizer)
    }

    // Keeps the poster and spinner above the player after a late embed,
    // without lifting them out of the container over the sheet.
    private func bringPlaybackChromeToFront() {
        if let poster = posterImageView {
            mediaContainer.bringSubviewToFront(poster)
        }
        if let spinner = posterSpinner {
            mediaContainer.bringSubviewToFront(spinner)
        }
        if let button = cellularPlayButton {
            mediaContainer.bringSubviewToFront(button)
        }
    }

    // Sizes the sheet content for the current page. The open or closed
    // position is applied afterwards so rotation does not leave a shown
    // sheet below the new bounds.
    private func layoutDetailsForCurrentBounds() {
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let height = panelHeight(for: viewSize)
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
            height: max(height, metadataSize.height)
        )
        applyDetailsProgress(isShowingDetails ? 1 : 0)
    }

    // Half the page, matching photo details, so the video stays visible
    // above the metadata instead of being replaced by it.
    private func panelHeight(for viewSize: CGSize) -> CGFloat {
        viewSize.height * 0.5
    }

    // Moves the video and the sheet together. Playback keeps running in
    // the space above the sheet instead of being covered by it.
    private func applyDetailsProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let height = panelHeight(for: viewSize)
        let hiddenMedia = CGRect(x: 0, y: 0, width: viewSize.width, height: viewSize.height)
        let shownMedia = CGRect(x: 0, y: 0, width: viewSize.width, height: viewSize.height - height)
        mediaContainer.frame = hiddenMedia.interpolated(to: shownMedia, progress: clamped)

        let hiddenPanel = CGRect(x: 0, y: viewSize.height, width: viewSize.width, height: height)
        let shownPanel = CGRect(x: 0, y: viewSize.height - height, width: viewSize.width, height: height)
        detailsPanelView.frame = hiddenPanel.interpolated(to: shownPanel, progress: clamped)
        detailsScrollView.frame = detailsPanelView.bounds
    }

    // Commits the sheet and notifies the pager. Closing resets the scroll
    // offset so the next open starts at the top of the metadata.
    private func setDetailsShown(_ shown: Bool, animated: Bool) {
        isShowingDetails = shown
        let animations = {
            self.applyDetailsProgress(shown ? 1 : 0)
        }
        if animated {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState],
                animations: animations
            )
        } else {
            animations()
        }
        if !shown {
            detailsScrollView.setContentOffset(.zero, animated: false)
        }
    }

    // The recognizer only supplies the finger's movement. The sheet
    // decision is shared with the test seam so both follow one path.
    @objc private func handleDetailsTogglePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        handleDetailsPan(
            state: recognizer.state,
            translationY: translation.y,
            velocityY: velocity.y
        )
    }

    // Tracks the finger and commits with the photo thresholds. A fast
    // flick counts even when the finger has not crossed half the sheet.
    private func handleDetailsPan(
        state: UIGestureRecognizer.State,
        translationY: CGFloat,
        velocityY: CGFloat
    ) {
        let height = panelHeight(for: view.bounds.size)
        switch state {
        case .began:
            panStartShowingDetails = isShowingDetails
        case .changed:
            guard height > 0 else { return }
            let progress: CGFloat
            if panStartShowingDetails {
                progress = min(max(1 - (translationY / height), 0), 1)
            } else {
                progress = min(max(-translationY / height, 0), 1)
            }
            applyDetailsProgress(progress)
        case .ended, .cancelled, .failed:
            if panStartShowingDetails {
                let shouldHide = DetailsPanelTransitionDecision.shouldHide(
                    translationY: translationY,
                    velocityY: velocityY
                )
                setDetailsShown(!shouldHide, animated: true)
            } else {
                let shouldShow = DetailsPanelTransitionDecision.shouldShow(
                    translationY: translationY,
                    velocityY: velocityY
                )
                setDetailsShown(shouldShow, animated: true)
            }
        default:
            break
        }
    }

    // Horizontal movement belongs to paging and the scrubber. An upward
    // swipe opens the sheet; a downward swipe on the video closes it.
    // A downward swipe on the sheet itself is left to the sheet's scroll
    // view so reading the metadata does not dismiss it.
    private func detailsPanShouldBegin(velocity: CGPoint, touchInsidePanel: Bool) -> Bool {
        let verticalDominant = abs(velocity.y) > abs(velocity.x) * DetailsPanelTransitionDecision.axisVelocityRatio
        guard verticalDominant else { return false }
        if isShowingDetails {
            guard velocity.y > 0 else { return false }
            return !touchInsidePanel
        }
        return velocity.y < 0
    }

    // Tears playback down if the pager never got a chance to stop this
    // controller, so a leaked player cannot keep playing after dismiss.
    deinit {
        posterLoadTask?.cancel()
        playerReadyObservation = nil
        playerRateObservation = nil
        let loader = fullResLoader
        Task { @MainActor in
            loader?.teardownPlayback()
        }
    }
}

// Provides test-only inspection hooks so fullscreen buffering regressions can
// be caught without exposing poster internals in release builds.
#if DEBUG
extension VideoPreviewViewController {
    // Exposes poster state so unit tests can validate fullscreen buffering UX.
    var testingPosterImage: UIImage? { posterImageView?.image }

    // Reports whether the buffering spinner is visible to the user.
    var testingHasSpinner: Bool { posterSpinner?.isAnimating == true }

    // Allows tests to drive embed behavior without weakening production API.
    func testingEmbedVideoPlayer(_ player: AVPlayer) {
        embedVideoPlayer(player: player)
    }

    // Reports pause invocations so lifecycle tests can assert cleanup happens.
    var testingPausePlaybackCount: Int { testingPausePlaybackCallCount }

    // Reports replay invocations so tests can validate swipe-back behavior.
    var testingRestartPlaybackCount: Int { testingRestartPlaybackInvocationCount }

    // Reports whether replay logic issued a seek-to-start request.
    var testingRestartRequestedSeekToStart: Bool { testingDidRequestSeekToStart }

    // Reports whether replay logic requested AVPlayer to resume playback.
    var testingRestartRequestedPlay: Bool { testingDidRequestPlayAfterRestart }

    // Injects a known player so lifecycle tests can verify pause semantics.
    @MainActor
    func testingInjectPlayerForLifecycle(_ player: AVPlayer) {
        fullResLoader?.teardownPlayback()
        let loader = FullResolutionImageLoader(timelineManager: timelineManager)
        loader.player = player
        fullResLoader = loader
    }

    // Allows tests to exercise swipe-back replay behavior directly.
    func testingRestartPlayback() {
        restartPlayback()
    }

    // Reports the mobile-data play affordance so tests can prove a remote
    // video did not start streaming on its own.
    var testingHasCellularPlayButton: Bool {
        cellularPlayButton?.superview != nil
    }

    // Reports whether the full-quality stream was requested.
    var testingDidStartVideoLoad: Bool { didStartVideoLoad }

    // Simulates accepting the data warning without presenting an alert.
    func testingConfirmCellularPlayback() {
        confirmCellularPlayback()
    }

    // Feeds a details pan so tests can prove the sheet opens and closes
    // without a window or a real touch.
    func testingDriveDetailsPan(
        state: UIGestureRecognizer.State,
        translationY: CGFloat,
        velocityY: CGFloat
    ) {
        handleDetailsPan(state: state, translationY: translationY, velocityY: velocityY)
    }

    // Uses the same gate as the recognizer so a horizontal swipe cannot
    // pass the test while the real pan still begins.
    func testingDetailsPanShouldBegin(velocity: CGPoint, touchInsidePanel: Bool) -> Bool {
        detailsPanShouldBegin(velocity: velocity, touchInsidePanel: touchInsidePanel)
    }

    // The video area the sheet pushes upward.
    var testingMediaContainerFrame: CGRect { mediaContainer.frame }
}
#endif

/// SwiftUI content for the video player, keeping the same accessibility
/// identifiers and playback state reporting as the prior VideoPlayerView.
private struct VideoPreviewContent: View {
    let player: AVPlayer
    @State private var isPlaying = false

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .accessibilityIdentifier("videoPlayer")
            .accessibilityValue(isPlaying ? "playing" : "paused")
            .onAppear {
                isPlaying = player.rate > 0
                observeRate()
            }
    }

    private func observeRate() {
        // KVO on rate to track play state
        _ = player.observe(\.rate, options: [.new]) { _, change in
            Task { @MainActor in
                isPlaying = (change.newValue ?? 0) > 0
            }
        }
    }
}

extension VideoPreviewViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === detailsScrollView, isShowingDetails else { return }
        // An overscroll past the top of the metadata means the user is
        // pulling the sheet down. Move it with the finger so closing
        // feels continuous, matching photo details.
        let offsetY = scrollView.contentOffset.y
        guard offsetY < 0 else { return }
        isInteractivelyClosing = true
        let pull = -offsetY
        let height = panelHeight(for: view.bounds.size)
        guard height > 0 else { return }
        applyDetailsProgress(min(max(1 - (pull / height), 0), 1))
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === detailsScrollView, isShowingDetails else { return }
        // A downward gesture only closes the sheet when the metadata is
        // already at the top. Otherwise it is normal scrolling.
        guard scrollView.contentOffset.y <= 0 else { return }
        let pull = -scrollView.contentOffset.y
        // Scroll view velocity is points per millisecond, with a downward
        // drag as negative y. The sheet decision uses points per second
        // and treats downward as positive.
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
        // A pull that did not cross the close threshold snaps back open.
        if isInteractivelyClosing && isShowingDetails {
            setDetailsShown(true, animated: true)
        }
        isInteractivelyClosing = false
    }
}

extension VideoPreviewViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === detailsTogglePanRecognizer,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        let insidePanel = detailsPanelView.frame.contains(gestureRecognizer.location(in: view))
        return detailsPanShouldBegin(
            velocity: pan.velocity(in: view),
            touchInsidePanel: insidePanel
        )
    }

    // VideoPlayer installs its own pans on the hosted view. They must wait
    // until this pan fails, or an upward swipe never reaches the sheet.
    // A horizontal swipe fails this pan immediately, so scrubbing still
    // runs. Paging and dismiss live on ancestors and are not claimed.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === detailsTogglePanRecognizer else { return false }
        guard let otherView = otherGestureRecognizer.view else { return false }
        return otherView.isDescendant(of: view)
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

private struct VideoErrorContent: View {
    let error: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.yellow)
            Text("Video playback error")
                .foregroundColor(.white)
                .font(.headline)
            Text(error)
                .foregroundColor(.white.opacity(0.7))
                .font(.caption)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}
