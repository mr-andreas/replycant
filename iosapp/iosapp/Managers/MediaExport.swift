import Foundation
import LibGit2
import Photos
import Security
import UniformTypeIdentifiers

/// Writes an original out of the library so it can be shared or saved.
///
/// The bytes stay the file the library stored. Re-encoding would drop
/// metadata and change the content hash, which makes photo sync upload
/// the camera-roll copy as a second item.

// Holds the identifier assigned inside `performChanges`. The change
// block cannot write a local variable, and the placeholder id is only
// valid to read there.
private final class CreatedLocalIdentifier: @unchecked Sendable {
    var value: String?
}

enum MediaExport {
    /// Failures the viewer can explain. Denied Photos access is its own
    /// case so the alert can offer Settings.
    enum MediaExportError: LocalizedError {
        case photoLibraryDenied
        case originalUnavailable
        case downloadFailed(Int)

        var errorDescription: String? {
            switch self {
            case .photoLibraryDenied:
                return "Allow Photos access to save to your camera roll."
            case .originalUnavailable:
                return "This item isn't available to export yet."
            case .downloadFailed(let status):
                return "The download failed (HTTP \(status))."
            }
        }
    }

    /// Picks a file name that stays inside the export folder. The
    /// original path is only a hint: a `..` segment must not escape
    /// the temp directory.
    nonisolated static func exportFileName(for item: TimelineItem) -> String {
        let candidate = (item.original.spec.path as NSString).lastPathComponent
        let safe = !candidate.isEmpty && candidate != "." && candidate != ".."
        if safe, !(candidate as NSString).pathExtension.isEmpty {
            return candidate
        }
        let base = item.original.metadata.name.isEmpty ? item.id : item.original.metadata.name
        if let mime = item.original.spec.mimeType,
           let ext = UTType(mimeType: mime)?.preferredFilenameExtension,
           !ext.isEmpty {
            return "\(base).\(ext)"
        }
        return base
    }

    /// Builds the decryptd direct-play request. The header carries the
    /// unwrapped DEK so the server can stream plaintext without the KEK.
    nonisolated static func makeVideoDownloadRequest(url: URL, dekBase64: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(dekBase64, forHTTPHeaderField: "X-Replycant-DEK")
        return request
    }

    /// Turns byte counts into a 0...1 ring fill. `expected` is the
    /// response length, or -1 when the server omitted it.
    /// `fallbackTotal` is the manifest file size used in that case.
    nonisolated static func downloadFraction(
        written: Int64,
        expected: Int64,
        fallbackTotal: Int64
    ) -> Double {
        let total = expected > 0 ? expected : fallbackTotal
        guard total > 0 else { return 0 }
        return min(1, Double(written) / Double(total))
    }

    /// Writes one original into a fresh temp folder and returns the
    /// file URL. Photos come from the local library or the original
    /// cache. Videos that are not already on device stream from
    /// decryptd so a large file is never held in memory.
    ///
    /// `onProgress` runs only for that server download, on the session
    /// queue, with a fraction in 0...1. Cancelling the task deletes
    /// the partial folder.
    @MainActor
    static func exportOriginal(
        item: TimelineItem,
        timelineManager: TimelineManager,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(exportFileName(for: item))
        do {
            if item.original.spec.mediaType == "video" {
                try await writeVideo(
                    item: item,
                    timelineManager: timelineManager,
                    to: destination,
                    onProgress: onProgress
                )
            } else {
                let data: Data
                do {
                    data = try await FullResolutionImageLoader.loadWhenConnected(
                        waitForNetwork: {
                            try await TailnetBootstrap.shared.waitUntilJoined()
                        }
                    ) {
                        try await FullResolutionImageLoader.loadOriginalImageData(
                            for: item,
                            priority: .fullscreenCurrent,
                            repository: timelineManager.repository,
                            lfsClient: timelineManager.lfsClient,
                            photoLibrary: timelineManager.photoLibrary
                        )
                    }
                } catch FullResolutionImageLoadError.repositoryNotAvailable,
                        FullResolutionImageLoadError.lfsClientNotAvailable {
                    throw MediaExportError.originalUnavailable
                }
                try data.write(to: destination, options: .atomic)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Adds the exported file to the camera roll. Add-only permission
    /// is enough, and the bytes are the original so sync will not
    /// upload the new asset a second time. The returned identifier is
    /// how a later Save knows this copy is already there.
    @MainActor
    static func saveToPhotos(fileURL: URL, isVideo: Bool) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else {
            throw MediaExportError.photoLibraryDenied
        }
        let created = CreatedLocalIdentifier()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let resourceType: PHAssetResourceType = isVideo ? .video : .photo
            request.addResource(with: resourceType, fileURL: fileURL, options: nil)
            created.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return created.value
    }

    /// True when Photos still has this item, either because this phone
    /// uploaded it or because Save already wrote it. Add-only access
    /// cannot see a later deletion, so the check stays false and Save
    /// proceeds.
    @MainActor
    static func isAlreadyInPhotos(
        item: TimelineItem,
        photoLibrary: PhotoLibraryProviding,
        savedMedia: SavedMediaStore
    ) -> Bool {
        guard photoLibrary.isAuthorized else { return false }
        if let localID = item.original.spec.localID, !localID.isEmpty,
           photoLibrary.assetExists(localIdentifier: localID) {
            return true
        }
        guard let savedID = savedMedia.localIdentifier(forItemID: item.id) else {
            return false
        }
        return photoLibrary.assetExists(localIdentifier: savedID)
    }

    // Copies a local Photos video when one exists, otherwise downloads
    // the decryptd original. Local copies are instant, so they do not
    // report progress.
    @MainActor
    private static func writeVideo(
        item: TimelineItem,
        timelineManager: TimelineManager,
        to destination: URL,
        onProgress: ((Double) -> Void)?
    ) async throws {
        if let localURL = await localVideoURL(for: item, timelineManager: timelineManager) {
            try FileManager.default.copyItem(at: localURL, to: destination)
            return
        }
        guard let repository = timelineManager.repository else {
            throw MediaExportError.originalUnavailable
        }
        let context = try FullResolutionImageLoader.resolveVideoPlaybackContext(
            item: item,
            repository: repository
        )
        let playbackURL = try FullResolutionImageLoader.makePlaybackURL(
            playbackMethod: .directPlay,
            objectID: context.encryptedOID,
            duration: item.original.spec.duration ?? 0,
            isUITesting: ProcessInfo.processInfo.arguments.contains("--uitesting"),
            lfsURLString: ServerConfigurationManager.shared.loadLFSURL(),
            gitURLString: ServerConfigurationManager.shared.loadURL()
        )
        let request = makeVideoDownloadRequest(url: playbackURL, dekBase64: context.dekBase64)
        try await FullResolutionImageLoader.loadWhenConnected(
            waitForNetwork: {
                try await TailnetBootstrap.shared.waitUntilJoined()
            }
        ) {
            try await downloadVideo(
                request: request,
                to: destination,
                fallbackTotal: item.original.spec.filesize,
                onProgress: onProgress
            )
        }
    }

    // Uses the same local-library rule as playback so a video that
    // never touched the server is not downloaded to be shared.
    @MainActor
    private static func localVideoURL(
        for item: TimelineItem,
        timelineManager: TimelineManager
    ) async -> URL? {
        guard CacheSettingsManager.shared.localThumbnailsEnabled else {
            return nil
        }
        let photoLibrary = timelineManager.photoLibrary
        guard photoLibrary.isAuthorized else {
            return nil
        }
        guard let localID = item.original.spec.localID, !localID.isEmpty else {
            return nil
        }
        return await photoLibrary.getVideoURL(forLocalIdentifier: localID)
    }

    // Streams plaintext to disk. `session` is injectable so a test can
    // serve the bytes without a live decryptd. The real export builds
    // a fresh mTLS session, which this method then closes.
    static func downloadVideo(
        request: URLRequest,
        to destination: URL,
        fallbackTotal: Int64,
        onProgress: ((Double) -> Void)?,
        session injectedSession: URLSession? = nil
    ) async throws {
        let session: URLSession
        if let injectedSession {
            session = injectedSession
        } else {
            session = try await PairingAuthorization.session()
        }
        let delegate = VideoDownloadDelegate(
            fallbackTotal: fallbackTotal,
            onProgress: onProgress,
            clientIdentity: ClientIdentityManager.shared.loadSecIdentity(),
            pinnedCA: ServerConfigurationManager.shared.loadSecCertificate()
        )
        let (downloaded, response): (URL, URLResponse)
        do {
            (downloaded, response) = try await withTaskCancellationHandler {
                try await session.download(for: request, delegate: delegate)
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch {
            session.finishTasksAndInvalidate()
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            session.finishTasksAndInvalidate()
            throw MediaExportError.downloadFailed(status)
        }
        do {
            try FileManager.default.moveItem(at: downloaded, to: destination)
        } catch {
            session.finishTasksAndInvalidate()
            throw error
        }
        // The task delegate can run after this method resumes, which
        // would leave the ring short of full when the share sheet
        // opens. Report completion here, where the caller is waiting.
        delegate.reportFinished()
        session.finishTasksAndInvalidate()
    }
}

/// Forwards gitd's mTLS challenge and reports download bytes.
///
/// `URLSession.download(for:delegate:)` delivers the task's challenges
/// here instead of to the session delegate that `PairingAuthorization`
/// installed, so this type has to present the device identity itself.
/// Progress comes from the task's own counters. The async download
/// API does not deliver `didWriteData`, and `task.progress` only
/// notifies key-value observers when the file is finished, so the
/// counters are read on a short timer while the body arrives.
private final class VideoDownloadDelegate: NSObject, URLSessionTaskDelegate {
    private let authDelegate: MTLSURLSessionAuthDelegate
    private let fallbackTotal: Int64
    private let onProgress: ((Double) -> Void)?
    private var pollTimer: DispatchSourceTimer?
    private let reportLock = NSLock()
    private var lastReported: Double = -1

    init(
        fallbackTotal: Int64,
        onProgress: ((Double) -> Void)?,
        clientIdentity: SecIdentity?,
        pinnedCA: SecCertificate?
    ) {
        self.fallbackTotal = fallbackTotal
        self.onProgress = onProgress
        self.authDelegate = MTLSURLSessionAuthDelegate(
            clientIdentity: clientIdentity,
            pinnedCA: pinnedCA
        )
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        authDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        authDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    // The task exists before any body bytes, so the ring can move as
    // they arrive instead of appearing only after the file is done.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "video-download-progress"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else { return }
            self.report(
                written: task.countOfBytesReceived,
                expected: task.countOfBytesExpectedToReceive
            )
        }
        pollTimer = timer
        timer.resume()
    }

    // A late timer tick can observe a reset count after the file is
    // done. Ignore anything that would move the ring backwards.
    private func report(written: Int64, expected: Int64) {
        let fraction = MediaExport.downloadFraction(
            written: written,
            expected: expected,
            fallbackTotal: fallbackTotal
        )
        reportLock.lock()
        let shouldReport = fraction > lastReported
        if shouldReport {
            lastReported = fraction
        }
        reportLock.unlock()
        if shouldReport {
            onProgress?(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if error == nil {
            report(
                written: task.countOfBytesReceived,
                expected: task.countOfBytesExpectedToReceive
            )
            reportFinished()
        } else {
            pollTimer?.cancel()
            pollTimer = nil
        }
    }

    // Counters are often already cleared once the file is on disk, so
    // a last poll can stop at a fraction. Callers waiting on the
    // download need the ring to reach full before they continue.
    func reportFinished() {
        pollTimer?.cancel()
        pollTimer = nil
        reportLock.lock()
        let shouldReport = lastReported < 1
        if shouldReport {
            lastReported = 1
        }
        reportLock.unlock()
        if shouldReport {
            onProgress?(1)
        }
    }
}
