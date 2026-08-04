import UIKit
import SwiftUI
import AVKit
import Combine

/// Displays one video in full screen within the UIPageViewController.
/// Hosts the AVPlayer via SwiftUI VideoPlayer for playback controls while
/// conforming to MediaPreviewControllable so the container can arbitrate
/// dismiss gestures against this child.
final class VideoPreviewViewController: UIViewController, MediaPreviewControllable {

    let item: TimelineItem
    private let timelineManager: TimelineManager
    private let onDismiss: () -> Void

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
    private var posterLoadTask: Task<Void, Never>?
    private var playerReadyObservation: NSKeyValueObservation?
    private var playerRateObservation: NSKeyValueObservation?
    private var hasAppeared = false
#if DEBUG
    private(set) var testingPausePlaybackCallCount = 0
    private(set) var testingRestartPlaybackInvocationCount = 0
    private(set) var testingDidRequestSeekToStart = false
    private(set) var testingDidRequestPlayAfterRestart = false
#endif

    init(item: TimelineItem, timelineManager: TimelineManager, onDismiss: @escaping () -> Void) {
        self.item = item
        self.timelineManager = timelineManager
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        _outerScrollView = UIScrollView(frame: view.bounds)
        _outerScrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        _outerScrollView.isScrollEnabled = false
        view.addSubview(_outerScrollView)

        setupPosterView()
        loadPosterImage()
        loadVideo()
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
        let loader = FullResolutionImageLoader(timelineManager: timelineManager)
        self.fullResLoader = loader

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

        loader.loadOriginal(for: item, isVideo: true)
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

    deinit {
        posterLoadTask?.cancel()
        playerReadyObservation = nil
        playerRateObservation = nil
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
        let loader = FullResolutionImageLoader(timelineManager: timelineManager)
        loader.player = player
        fullResLoader = loader
    }

    // Allows tests to exercise swipe-back replay behavior directly.
    func testingRestartPlayback() {
        restartPlayback()
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
