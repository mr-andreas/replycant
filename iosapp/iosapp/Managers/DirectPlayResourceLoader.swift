import AVFoundation
import Foundation
import LibGit2
import Security
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.replycant.app", category: "DirectPlay")

/// Intercepts AVAssetResourceLoader requests for a custom URL scheme so
/// AVPlayer can stream from decryptd's extensionless `/objects/{oid}` endpoint
/// with proper content-type and DEK headers on every sub-request.
///
/// AVPlayer cannot determine media type from a bare `/objects/{hash}` URL.
/// Using a custom scheme (`replycant-dplay://`) triggers this delegate which
/// proxies the request to the real HTTP URL while declaring the correct UTI
/// and forwarding Range headers — ensuring progressive MP4/MOV streaming
/// works without modifying the decryptd server.
final class DirectPlayResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "replycant-dplay"

    var onSeekRangeReplacementStarted: (@MainActor () -> Void)?
    var onSeekRangeReplacementReady: (@MainActor () -> Void)?

    private let httpURL: URL
    private let headers: [String: String]
    private let uniformTypeIdentifier: String

    // decryptd is only reachable through gitd's mTLS endpoint, so every
    // sub-request this loader issues must present the device identity and pin
    // the server to the onboarded CA. Reusing the shared delegate keeps that
    // logic identical to the Git and LFS clients.
    private let authDelegate: MTLSURLSessionAuthDelegate
    private let lock = NSLock()
    private var sessions: [Int: LoadingSession] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var tasksByTaskID: [Int: URLSessionDataTask] = [:]
    private var latestOpenEndedRangeDescription: String?
    private var seekReplacementTaskIDs = Set<Int>()
    private let sessionDelegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private lazy var urlSession = URLSession(
        configuration: .ephemeral,
        delegate: self,
        delegateQueue: sessionDelegateQueue
    )

    private final class LoadingSession {
        let loadingRequest: AVAssetResourceLoadingRequest
        let rangeDescription: String
        let isOpenEndedDataRequest: Bool
        var hasDeliveredData = false

        init(
            loadingRequest: AVAssetResourceLoadingRequest,
            rangeDescription: String,
            isOpenEndedDataRequest: Bool
        ) {
            self.loadingRequest = loadingRequest
            self.rangeDescription = rangeDescription
            self.isOpenEndedDataRequest = isOpenEndedDataRequest
        }
    }

    /// - Parameters:
    ///   - httpURL: The real `https://` gitd `/decryptd` URL.
    ///   - headers: DEK and chunk-size headers for every request.
    ///   - mimeType: MIME type (e.g. `video/mp4`) — converted to UTI internally.
    ///   - clientIdentity: Device identity presented to gitd's mTLS endpoint.
    ///   - pinnedCA: CA captured during onboarding, used to pin the server chain.
    init(
        httpURL: URL,
        headers: [String: String],
        mimeType: String,
        clientIdentity: SecIdentity?,
        pinnedCA: SecCertificate?
    ) {
        self.httpURL = httpURL
        self.headers = headers
        self.uniformTypeIdentifier = UTType(mimeType: mimeType)?.identifier ?? UTType.mpeg4Movie.identifier
        self.authDelegate = MTLSURLSessionAuthDelegate(clientIdentity: clientIdentity, pinnedCA: pinnedCA)
        super.init()
    }

    // Stops in-flight range requests and breaks the URLSession-to-delegate
    // retain so a dismissed player cannot keep streaming after teardown.
    func invalidate() {
        onSeekRangeReplacementStarted = nil
        onSeekRangeReplacementReady = nil
        lock.lock()
        let pending = Array(tasks.values)
        tasks.removeAll()
        tasksByTaskID.removeAll()
        sessions.removeAll()
        seekReplacementTaskIDs.removeAll()
        lock.unlock()
        for task in pending {
            task.cancel()
        }
        urlSession.invalidateAndCancel()
    }

    static func customSchemeURL(from httpURL: URL) -> URL? {
        guard var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = scheme
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        fulfillLoadingRequest(loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        let requestID = ObjectIdentifier(loadingRequest)
        let task = tasks.removeValue(forKey: requestID)
        let session: LoadingSession?
        if let task {
            session = sessions.removeValue(forKey: task.taskIdentifier)
            tasksByTaskID.removeValue(forKey: task.taskIdentifier)
        } else {
            session = nil
        }
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Request fulfillment

    /// Handles content-info and data in one pass since AVFoundation often
    /// sends both on the initial loading request.
    private func fulfillLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        var request = URLRequest(url: httpURL)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let rangeDescription: String
        let isOpenEndedDataRequest: Bool
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            let length = Int64(dataRequest.requestedLength)
            isOpenEndedDataRequest = dataRequest.requestsAllDataToEndOfResource
            if isOpenEndedDataRequest {
                rangeDescription = "bytes=\(offset)-"
            } else {
                let end = offset + length - 1
                rangeDescription = "bytes=\(offset)-\(end)"
            }
            request.setValue(rangeDescription, forHTTPHeaderField: "Range")
        } else {
            request.httpMethod = "HEAD"
            rangeDescription = "HEAD"
            isOpenEndedDataRequest = false
            logger.debug("Sending HEAD probe")
        }

        let task = urlSession.dataTask(with: request)
        let replacement = replaceOpenEndedRangeIfNeeded(
            taskID: task.taskIdentifier,
            replacingWith: rangeDescription,
            isOpenEndedDataRequest: isOpenEndedDataRequest
        )
        lock.lock()
        sessions[task.taskIdentifier] = LoadingSession(
            loadingRequest: loadingRequest,
            rangeDescription: rangeDescription,
            isOpenEndedDataRequest: isOpenEndedDataRequest
        )
        tasks[ObjectIdentifier(loadingRequest)] = task
        tasksByTaskID[task.taskIdentifier] = task
        lock.unlock()
        if replacement.didReplaceRange {
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    self?.onSeekRangeReplacementStarted?()
                }
            }
        }
        for staleTask in replacement.staleTasks {
            staleTask.cancel()
        }
        task.resume()
    }

    /// A post-scrub request should take over immediately. Otherwise an older
    /// `bytes=N-` stream can keep feeding the pre-scrub position until the new
    /// target buffers, which makes playback appear to resume from the wrong
    /// time for a moment.
    private func replaceOpenEndedRangeIfNeeded(
        taskID: Int,
        replacingWith rangeDescription: String,
        isOpenEndedDataRequest: Bool
    ) -> (staleTasks: [URLSessionDataTask], didReplaceRange: Bool) {
        guard isOpenEndedDataRequest else { return ([], false) }

        lock.lock()
        defer { lock.unlock() }

        let didReplaceRange = latestOpenEndedRangeDescription.map {
            $0 != rangeDescription
        } ?? false
        latestOpenEndedRangeDescription = rangeDescription
        if didReplaceRange {
            seekReplacementTaskIDs.insert(taskID)
        }

        var staleTasks: [URLSessionDataTask] = []
        let staleTaskIDs = sessions.compactMap { taskID, session in
            session.isOpenEndedDataRequest && session.rangeDescription != rangeDescription ? taskID : nil
        }
        for taskID in staleTaskIDs {
            guard let session = sessions.removeValue(forKey: taskID) else {
                continue
            }
            if let task = tasksByTaskID.removeValue(forKey: taskID) {
                staleTasks.append(task)
                tasks.removeValue(forKey: ObjectIdentifier(session.loadingRequest))
            }
            logger.debug(
                "Cancelling stale \(session.rangeDescription, privacy: .public) stream for new \(rangeDescription, privacy: .public) request"
            )
        }
        return (staleTasks, didReplaceRange)
    }

    private func session(for task: URLSessionTask) -> LoadingSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[task.taskIdentifier]
    }

    private func removeSession(for task: URLSessionTask) -> LoadingSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions.removeValue(forKey: task.taskIdentifier) else {
            return nil
        }
        tasksByTaskID.removeValue(forKey: task.taskIdentifier)
        tasks.removeValue(forKey: ObjectIdentifier(session.loadingRequest))
        return session
    }
}

extension DirectPlayResourceLoader: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        authDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let loadingSession = self.session(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.error("HTTP error: \(code)")
            completionHandler(.cancel)
            return
        }

        if let contentInfo = loadingSession.loadingRequest.contentInformationRequest {
            contentInfo.contentType = uniformTypeIdentifier
            contentInfo.isByteRangeAccessSupported = true
            contentInfo.contentLength = contentLength(from: httpResponse)
            logger.debug(
                "Content info: type=\(self.uniformTypeIdentifier, privacy: .public) length=\(contentInfo.contentLength)"
            )
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let loadingSession = self.markDataDelivered(for: dataTask),
              let dataRequest = loadingSession.loadingRequest.dataRequest else {
            return
        }
        dataRequest.respond(with: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let loadingSession = removeSession(for: task) else {
            return
        }
        if let error = error as? URLError, error.code == .cancelled {
            return
        }
        if let error {
            logger.error("Network error: \(error.localizedDescription, privacy: .public)")
            loadingSession.loadingRequest.finishLoading(with: error)
        } else {
            loadingSession.loadingRequest.finishLoading()
        }
    }

    private func contentLength(from response: HTTPURLResponse) -> Int64 {
        if let rangeHeader = response.value(forHTTPHeaderField: "Content-Range"),
           let slashIdx = rangeHeader.lastIndex(of: "/"),
           let total = Int64(rangeHeader[rangeHeader.index(after: slashIdx)...]) {
            return total
        }
        if let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(contentLength) {
            return length
        }
        return 0
    }

    private func markDataDelivered(for task: URLSessionTask) -> LoadingSession? {
        lock.lock()
        guard let session = sessions[task.taskIdentifier] else {
            lock.unlock()
            return nil
        }
        let shouldResume = seekReplacementTaskIDs.remove(task.taskIdentifier) != nil && !session.hasDeliveredData
        session.hasDeliveredData = true
        lock.unlock()

        if shouldResume {
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    self?.onSeekRangeReplacementReady?()
                }
            }
        }

        return session
    }
}
