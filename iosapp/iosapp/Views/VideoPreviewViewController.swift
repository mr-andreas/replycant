import UIKit
import SwiftUI
import AVKit
import Combine
import GitDB

/// Displays one video in full screen within the UIPageViewController.
/// Hosts the AVPlayer via SwiftUI VideoPlayer for playback controls while
/// conforming to MediaPreviewControllable so the container can arbitrate
/// dismiss gestures against this child.
final class VideoPreviewViewController: UIViewController, MediaPreviewControllable {

    let item: TimelineItem
    private let timelineManager: TimelineManager
    private let onDismiss: () -> Void
    private let networkCost: NetworkCostProviding

    private var _outerScrollView: UIScrollView!
    var outerScrollView: UIScrollView { _outerScrollView }
    var currentZoomScale: CGFloat { 1.0 }
    var isShowingDetails: Bool { false }
    var onDetailsVisibilityChanged: ((Bool) -> Void)?

    private var fullResLoader: FullResolutionImageLoader?
    private var cancellables = Set<AnyCancellable>()
    private var hostController: UIHostingController<AnyView>?
    private var posterImageView: UIImageView?
    private var posterSpinner: UIActivityIndicatorView?
    private var cellularPlayButton: UIButton?
    private var posterLoadTask: Task<Void, Never>?
    private var playerReadyObservation: NSKeyValueObservation?
    private var playerRateObservation: NSKeyValueObservation?
    private var hasAppeared = false
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

    // Chooses autoplay or a mobile-data hold before any bytes are requested,
    // so opening a video on cellular does not start the full-quality stream.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        _outerScrollView = UIScrollView(frame: view.bounds)
        _outerScrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        _outerScrollView.isScrollEnabled = false
        view.addSubview(_outerScrollView)

        setupPosterView()
        loadPosterImage()
        if networkCost.isMetered {
            resolveLocalOrHoldForConfirmation()
        } else {
            loadVideo()
        }
    }

    // Restarts video when users return to this cached page so swipe-back always
    // replays from the beginning instead of showing a paused prior position.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard hasAppeared else {
            hasAppeared = true
            return
        }
        restartPlayback()
    }

    // Stops playback when the fullscreen controller leaves the screen so
    // dismissal gestures never leave audio running in the background.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pausePlayback()
    }

    // Centralizes pause behavior so all dismissal paths share one cleanup step.
    func pausePlayback() {
#if DEBUG
        testingPausePlaybackCallCount += 1
#endif
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
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 88),
            button.heightAnchor.constraint(equalToConstant: 88),
        ])
        cellularPlayButton = button
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
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        hostController = host

        if let poster = posterImageView {
            view.bringSubviewToFront(poster)
        }
        if let spinner = posterSpinner {
            view.bringSubviewToFront(spinner)
        }

        observePlayerReadiness(player)
        player.play()
    }

    // Shows the same thumbnail users saw in the timeline so fullscreen video
    // avoids an abrupt black frame during initial buffering. A centered spinner
    // signals that playback is loading.
    private func setupPosterView() {
        let imageView = UIImageView(frame: view.bounds)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = false
        imageView.accessibilityIdentifier = "videoPosterImage"
        view.addSubview(imageView)
        posterImageView = imageView

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
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
        let thumbnailPath = "binary/\(deviceSpace)/media.replycant.com/v1alpha1/ThumbnailSet/\(shardName(thumbnail.name))"
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
            let imageView = UIImageView(frame: view.bounds)
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black
            imageView.isUserInteractionEnabled = false
            imageView.accessibilityIdentifier = "videoPosterImage"
            imageView.image = timelineManager.getCachedImage(for: item.id)
            view.addSubview(imageView)
            posterImageView = imageView
        }
        if posterSpinner == nil {
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.color = .white
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.hidesWhenStopped = true
            view.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            spinner.startAnimating()
            posterSpinner = spinner
        }
        if let poster = posterImageView {
            view.bringSubviewToFront(poster)
        }
        if let spinner = posterSpinner {
            view.bringSubviewToFront(spinner)
        }
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
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
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

    // Reports appearance lifecycle state so tests can verify first-entry guard.
    var testingHasAppeared: Bool { hasAppeared }

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
