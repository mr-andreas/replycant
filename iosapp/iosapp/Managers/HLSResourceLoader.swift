import AVFoundation
import Foundation
import LibGit2
import Security
import os.log

private let hlsLogger = Logger(subsystem: "com.replycant.app", category: "HLSPlayback")

/// Serves HLS playlists and segments to AVPlayer over gitd's mTLS endpoint.
///
/// transcoded is no longer exposed on its own port; it is reachable only
/// through gitd, which requires a client certificate. AVPlayer fetches
/// playlists and segments with its own internal HTTP stack and offers no way to
/// supply a client identity, so native HLS playback cannot authenticate on its
/// own. Registering this delegate against a custom scheme (`replycant-hls`)
/// moves every sub-request onto a URLSession we control, where the shared mTLS
/// delegate can present the device identity and pin the server CA.
///
/// This relies on transcoded emitting *relative* playlist URIs: AVFoundation
/// resolves them against the custom-scheme base URL, so variant playlists and
/// segments arrive here already under `replycant-hls://` and no playlist body
/// rewriting is needed.
///
/// Known risk: full-playlist interception through `AVAssetResourceLoaderDelegate`
/// is widely relied upon but not a formally documented AVFoundation guarantee.
/// If a future OS rejects the custom scheme, the fallback is an on-device HTTP
/// relay on `127.0.0.1` that terminates mTLS and serves plain HTTP to AVPlayer.
final class HLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "replycant-hls"

    private let headers: [String: String]
    private let authDelegate: MTLSURLSessionAuthDelegate
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private lazy var urlSession = URLSession(
        configuration: .ephemeral,
        delegate: authDelegate,
        delegateQueue: nil
    )

    /// - Parameters:
    ///   - headers: DEK and chunk-size headers forwarded on every sub-request.
    ///   - clientIdentity: Device identity presented to gitd's mTLS endpoint.
    ///   - pinnedCA: CA captured during onboarding, used to pin the server chain.
    init(headers: [String: String], clientIdentity: SecIdentity?, pinnedCA: SecCertificate?) {
        self.headers = headers
        self.authDelegate = MTLSURLSessionAuthDelegate(clientIdentity: clientIdentity, pinnedCA: pinnedCA)
        super.init()
    }

    /// Rewrites an https playlist URL into the custom scheme so AVFoundation
    /// routes it, and everything it resolves relative to it, through this loader.
    static func customSchemeURL(from httpURL: URL) -> URL? {
        guard var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = scheme
        return components.url
    }

    /// Maps a custom-scheme sub-request back to the real https URL.
    static func httpURL(from customURL: URL) -> URL? {
        guard var components = URLComponents(url: customURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard components.scheme == scheme else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// Declares the media type for a sub-request so AVFoundation can parse the
    /// response without relying on the URL extension it never sees.
    static func contentType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "m3u8":
            return "public.m3u8-playlist"
        case "ts":
            return "public.mpeg-2-transport-stream"
        default:
            return nil
        }
    }

    /// Builds the authenticated upstream request for one AVFoundation sub-request.
    static func makeRequest(for customURL: URL, headers: [String: String]) -> URLRequest? {
        guard let httpURL = httpURL(from: customURL) else { return nil }
        var request = URLRequest(url: httpURL)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Resolves the *total* resource size AVFoundation needs to plan seeking.
    ///
    /// The loader advertises byte-range support and issues ranged sub-requests,
    /// so a response body is frequently just one slice. Reporting that slice as
    /// the content length makes AVFoundation treat the first chunk as the whole
    /// resource, so the total from `Content-Range` wins whenever it is present.
    /// Zero is returned when upstream supplies no size metadata at all, since
    /// guessing from the payload is what reintroduces the truncation this avoids.
    static func contentLength(from response: HTTPURLResponse) -> Int64 {
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

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let customURL = loadingRequest.request.url,
              var request = Self.makeRequest(for: customURL, headers: headers) else {
            loadingRequest.finishLoading(with: URLError(.badURL))
            return true
        }

        if let dataRequest = loadingRequest.dataRequest, !dataRequest.requestsAllDataToEndOfResource {
            let start = dataRequest.requestedOffset
            let end = start + Int64(dataRequest.requestedLength) - 1
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }

        let requestID = ObjectIdentifier(loadingRequest)
        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.forgetTask(for: requestID)

            if let error {
                if (error as? URLError)?.code == .cancelled { return }
                hlsLogger.error("HLS sub-request failed: \(error.localizedDescription, privacy: .public)")
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                hlsLogger.error("HLS sub-request HTTP error: \(code)")
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }

            if let contentInfo = loadingRequest.contentInformationRequest {
                contentInfo.contentType = Self.contentType(for: customURL)
                contentInfo.isByteRangeAccessSupported = true
                contentInfo.contentLength = Self.contentLength(from: httpResponse)
            }
            if let data {
                loadingRequest.dataRequest?.respond(with: data)
            }
            loadingRequest.finishLoading()
        }

        lock.lock()
        tasks[requestID] = task
        lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        let task = tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
        lock.unlock()
        task?.cancel()
    }

    private func forgetTask(for requestID: ObjectIdentifier) {
        lock.lock()
        tasks.removeValue(forKey: requestID)
        lock.unlock()
    }
}
