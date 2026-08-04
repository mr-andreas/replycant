import Foundation
import Clibgit2
import Security

// Provides a custom libgit2 smart transport for mtls+https:// URLs, enabling
// libgit2 to perform push/pull while we handle mTLS authentication via URLSession.
// This allows libgit2 to own the Git protocol (pack negotiation, report-status)
// while we provide the network layer with SecIdentity + pinned CA support.
public final class MTLSTransport: NSObject {
    
    public static let shared = MTLSTransport()
    
    private var clientIdentity: SecIdentity?
    private var pinnedCA: SecCertificate?
    private var isRegistered = false
    
    private override init() {
        super.init()
    }
    
    // Configures the transport with mTLS credentials and registers the mtls+https scheme.
    // Must be called before any Git network operations that use mtls+https:// URLs.
    public func configure(clientIdentity: SecIdentity, pinnedCA: SecCertificate) throws {
        logDebug("Configuring with identity and CA...", context: "MTLSTransport")
        self.clientIdentity = clientIdentity
        self.pinnedCA = pinnedCA

        if !isRegistered {
            log("Transport not yet registered, registering now...", context: "MTLSTransport")
            try registerTransport()
            isRegistered = true
            log("Transport registration complete", context: "MTLSTransport")
        } else {
            logDebug("Transport already registered, updating credentials only", context: "MTLSTransport")
        }
    }
    
    // Registers the mtls+https:// scheme with libgit2's transport system.
    private func registerTransport() throws {
        // Ensure libgit2 is initialized before registering custom transports
        try Git.initialize()
        
        // Create the subtransport definition (must persist for the lifetime of the app)
        let definitionPtr = UnsafeMutablePointer<git_smart_subtransport_definition>.allocate(capacity: 1)
        definitionPtr.pointee.callback = mtlsSubtransportCallback
        definitionPtr.pointee.rpc = 1 // HTTP is stateless/RPC
        definitionPtr.pointee.param = nil
        
        // Register the transport using a C-compatible function
        let result = git_transport_register(
            "mtls+https",
            mtlsTransportFactoryCallback,
            definitionPtr
        )
        
        guard result == 0 else {
            definitionPtr.deallocate()
            logError("Registration failed with code \(result)", context: "MTLSTransport")
            throw MTLSTransportError.registrationFailed(code: result)
        }

        log("Registered mtls+https:// scheme successfully", context: "MTLSTransport")
    }
    
    // Returns the configured client identity for mTLS authentication.
    func getClientIdentity() -> SecIdentity? {
        return clientIdentity
    }
    
    // Returns the pinned CA certificate for server validation.
    func getPinnedCA() -> SecCertificate? {
        return pinnedCA
    }
}

// MARK: - Subtransport Implementation

// Context stored in the subtransport for accessing Swift objects from C callbacks.
private final class SubtransportContext {
    var activeStream: StreamContext?
    var session: URLSession?
    var sessionDelegate: StreamingDataDelegate?
}

// Context stored in each stream for managing the HTTP request/response.
private final class StreamContext {
    let url: String
    let action: git_smart_service_t
    let subtransportContext: SubtransportContext
    var requestBody = Data()
    let responseBuffer = StreamingBuffer(maxBufferedBytes: 4 * 1024 * 1024)
    var task: URLSessionDataTask?
    var error: Error?
    var requestStarted = false
    
    init(url: String, action: git_smart_service_t, subtransportContext: SubtransportContext) {
        self.url = url
        self.action = action
        self.subtransportContext = subtransportContext
    }
}

// URLSession delegate that handles mTLS authentication challenges.
private final class MTLSURLSessionDelegate: NSObject, URLSessionDelegate {
    let clientIdentity: SecIdentity
    let pinnedCA: SecCertificate
    
    init(clientIdentity: SecIdentity, pinnedCA: SecCertificate) {
        self.clientIdentity = clientIdentity
        self.pinnedCA = pinnedCA
        super.init()
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            handleServerTrust(challenge, completionHandler: completionHandler)
        case NSURLAuthenticationMethodClientCertificate:
            handleClientCertificate(challenge, completionHandler: completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    private func handleServerTrust(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Verify server certificate against pinned CA
        if verifyCertificateChain(serverTrust: serverTrust) {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    
    private func verifyCertificateChain(serverTrust: SecTrust) -> Bool {
        guard let chainArray = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            return false
        }
        
        let pinnedCAData = SecCertificateCopyData(pinnedCA) as Data
        
        // Check if pinned CA is in the chain
        for cert in chainArray {
            let certData = SecCertificateCopyData(cert) as Data
            if certData == pinnedCAData {
                return true
            }
        }
        
        // Try to verify leaf is signed by pinned CA
        if let leafCert = chainArray.first {
            return verifyLeafCert(leafCert: leafCert)
        }
        
        return false
    }
    
    private func verifyLeafCert(leafCert: SecCertificate) -> Bool {
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        
        let status = SecTrustCreateWithCertificates(
            [leafCert, pinnedCA] as CFArray,
            policy,
            &trust
        )
        
        guard status == errSecSuccess, let trust = trust else {
            return false
        }
        
        SecTrustSetAnchorCertificates(trust, [pinnedCA] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
    
    private func handleClientCertificate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let credential = URLCredential(
            identity: clientIdentity,
            certificates: nil,
            persistence: .forSession
        )
        completionHandler(.useCredential, credential)
    }
}

// Provides a bounded producer-consumer buffer for transport response streaming.
private final class StreamingBuffer {
    private enum ReadState {
        case bytes(Int)
        case eof
        case failure(Error)
    }
    
    private let condition = NSCondition()
    private var storage = Data()
    private var readOffset = 0
    private var isFinished = false
    private var streamError: Error?
    private let maxBufferedBytes: Int
    
    init(maxBufferedBytes: Int) {
        self.maxBufferedBytes = maxBufferedBytes
    }
    
    // Appends response bytes and blocks when the buffer reaches its high-water mark.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        
        condition.lock()
        while availableBytes >= maxBufferedBytes && streamError == nil && !isFinished {
            condition.wait()
        }
        
        if streamError != nil || isFinished {
            condition.unlock()
            return
        }
        
        storage.append(data)
        condition.broadcast()
        condition.unlock()
    }
    
    // Signals a terminal stream error so blocked readers can fail immediately.
    func fail(_ error: Error) {
        condition.lock()
        streamError = error
        condition.broadcast()
        condition.unlock()
    }
    
    // Signals end-of-stream once the producer has finished sending all bytes.
    func finish() {
        condition.lock()
        isFinished = true
        condition.broadcast()
        condition.unlock()
    }
    
    // Reads up to maxCount bytes into the provided C buffer, blocking until data/EOF/error.
    func read(into buffer: UnsafeMutablePointer<CChar>, maxCount: Int) -> (bytesRead: Int, error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        
        while availableBytes == 0 && !isFinished && streamError == nil {
            condition.wait()
        }
        
        switch currentReadState(maxCount: maxCount) {
        case .bytes(let count):
            storage.withUnsafeBytes { ptr in
                let source = ptr.baseAddress!.advanced(by: readOffset)
                buffer.update(from: source.assumingMemoryBound(to: CChar.self), count: count)
            }
            readOffset += count
            trimIfNeeded()
            condition.broadcast()
            return (count, nil)
        case .eof:
            return (0, nil)
        case .failure(let error):
            return (0, error)
        }
    }
    
    private var availableBytes: Int {
        storage.count - readOffset
    }
    
    private func currentReadState(maxCount: Int) -> ReadState {
        if let streamError {
            return .failure(streamError)
        }
        
        let available = availableBytes
        if available == 0 && isFinished {
            return .eof
        }
        
        let toRead = min(available, maxCount)
        return .bytes(toRead)
    }
    
    private func trimIfNeeded() {
        if readOffset == storage.count {
            storage.removeAll(keepingCapacity: true)
            readOffset = 0
            return
        }
        
        if readOffset >= 64 * 1024 && readOffset * 2 >= storage.count {
            storage.removeSubrange(0..<readOffset)
            readOffset = 0
        }
    }
}

// Streams URLSession data chunks into the transport buffer for incremental libgit2 reads.
private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate {
    private let authDelegate: MTLSURLSessionDelegate
    private var buffersByTaskId: [Int: StreamingBuffer] = [:]
    private let taskMapLock = NSLock()
    
    init(authDelegate: MTLSURLSessionDelegate) {
        self.authDelegate = authDelegate
        super.init()
    }

    // Maps a URLSession task to the stream buffer that should receive its bytes.
    func register(task: URLSessionTask, responseBuffer: StreamingBuffer) {
        taskMapLock.lock()
        buffersByTaskId[task.taskIdentifier] = responseBuffer
        taskMapLock.unlock()
    }

    // Removes a completed/cancelled task mapping to avoid leaking buffers.
    func unregister(taskIdentifier: Int) {
        taskMapLock.lock()
        buffersByTaskId.removeValue(forKey: taskIdentifier)
        taskMapLock.unlock()
    }

    // Finds the stream buffer currently associated with the URLSession task.
    private func responseBuffer(for task: URLSessionTask) -> StreamingBuffer? {
        taskMapLock.lock()
        let buffer = buffersByTaskId[task.taskIdentifier]
        taskMapLock.unlock()
        return buffer
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
    
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let responseBuffer = responseBuffer(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            responseBuffer.fail(MTLSTransportError.networkError("No HTTP response"))
            completionHandler(.cancel)
            return
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            responseBuffer.fail(MTLSTransportError.networkError("HTTP error \(httpResponse.statusCode)"))
            completionHandler(.cancel)
            return
        }
        
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let responseBuffer = responseBuffer(for: dataTask) else { return }
        responseBuffer.append(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let responseBuffer = responseBuffer(for: task) else { return }
        unregister(taskIdentifier: task.taskIdentifier)
        if let error {
            let nsError = error as NSError
            logError("Task completed with error: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)", context: "MTLSTransport")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                logError("Underlying error: domain=\(underlying.domain) code=\(underlying.code) \(underlying.localizedDescription)", context: "MTLSTransport")
            }
            responseBuffer.fail(error)
        } else {
            responseBuffer.finish()
        }
    }
}

// MARK: - C Callback Functions

// Transport factory callback - creates a smart transport with our subtransport definition.
// Must be a top-level function with @convention(c) to be compatible with libgit2's C API.
private let mtlsTransportFactoryCallback: git_transport_cb = { (out, owner, payload) -> Int32 in
    logDebug("Factory callback invoked", context: "MTLSTransport")
    return git_transport_smart(out, owner, payload)
}

// Creates a new subtransport instance for the smart transport.
private func mtlsSubtransportCallback(
    out: UnsafeMutablePointer<UnsafeMutablePointer<git_smart_subtransport>?>?,
    owner: UnsafeMutablePointer<git_transport>?,
    param: UnsafeMutableRawPointer?
) -> Int32 {
    // Allocate the subtransport structure
    let subtransport = UnsafeMutablePointer<git_smart_subtransport>.allocate(capacity: 1)
    
    // Create context for this subtransport
    let context = SubtransportContext()
    let contextPtr = Unmanaged.passRetained(context).toOpaque()
    
    // Set up the subtransport callbacks
    subtransport.pointee.action = { (outStream, transport, url, action) -> Int32 in
        return mtlsSubtransportAction(outStream: outStream, transport: transport, url: url, action: action)
    }
    
    subtransport.pointee.close = { transport -> Int32 in
        return mtlsSubtransportClose(transport: transport)
    }
    
    subtransport.pointee.free = { transport in
        mtlsSubtransportFree(transport: transport)
    }
    
    // Store context pointer in a way we can retrieve it (use the subtransport address as key)
    subtransportContexts[subtransport] = contextPtr
    
    out?.pointee = subtransport
    return 0
}

// Global storage for subtransport contexts (keyed by subtransport pointer)
private var subtransportContexts: [UnsafeMutablePointer<git_smart_subtransport>: UnsafeMutableRawPointer] = [:]

// Global storage for stream contexts (keyed by stream pointer)
private var streamContexts: [UnsafeMutablePointer<git_smart_subtransport_stream>: StreamContext] = [:]

// Handles an action request from the smart transport.
private func mtlsSubtransportAction(
    outStream: UnsafeMutablePointer<UnsafeMutablePointer<git_smart_subtransport_stream>?>?,
    transport: UnsafeMutablePointer<git_smart_subtransport>?,
    url: UnsafePointer<CChar>?,
    action: git_smart_service_t
) -> Int32 {
    guard let transport = transport,
          let url = url,
          let outStream = outStream else {
        return -1
    }
    
    let urlString = String(cString: url)
    logDebug("Action \(action.rawValue) for \(urlString)", context: "MTLSTransport")
    
    // Create stream structure
    let stream = UnsafeMutablePointer<git_smart_subtransport_stream>.allocate(capacity: 1)
    stream.pointee.subtransport = transport
    
    stream.pointee.read = { (stream, buffer, bufSize, bytesRead) -> Int32 in
        return mtlsStreamRead(stream: stream, buffer: buffer, bufSize: bufSize, bytesRead: bytesRead)
    }
    
    stream.pointee.write = { (stream, buffer, len) -> Int32 in
        return mtlsStreamWrite(stream: stream, buffer: buffer, len: len)
    }
    
    stream.pointee.free = { stream in
        mtlsStreamFree(stream: stream)
    }
    
    guard let contextPtr = subtransportContexts[transport] else {
        stream.deallocate()
        return -1
    }
    let subtransportContext = Unmanaged<SubtransportContext>.fromOpaque(contextPtr).takeUnretainedValue()
    
    // Create context for this stream
    let context = StreamContext(url: urlString, action: action, subtransportContext: subtransportContext)
    streamContexts[stream] = context
    
    outStream.pointee = stream
    return 0
}

// Closes the subtransport connection.
private func mtlsSubtransportClose(transport: UnsafeMutablePointer<git_smart_subtransport>?) -> Int32 {
    guard let transport = transport,
          let contextPtr = subtransportContexts[transport] else {
        return 0
    }
    
    let context = Unmanaged<SubtransportContext>.fromOpaque(contextPtr).takeUnretainedValue()
    context.session?.invalidateAndCancel()
    context.session = nil
    context.sessionDelegate = nil
    return 0
}

// Frees the subtransport resources.
private func mtlsSubtransportFree(transport: UnsafeMutablePointer<git_smart_subtransport>?) {
    guard let transport = transport else { return }
    _ = mtlsSubtransportClose(transport: transport)
    
    if let contextPtr = subtransportContexts.removeValue(forKey: transport) {
        Unmanaged<SubtransportContext>.fromOpaque(contextPtr).release()
    }
    
    transport.deallocate()
}

// Writes data to the stream (called by libgit2 to send request body).
private func mtlsStreamWrite(
    stream: UnsafeMutablePointer<git_smart_subtransport_stream>?,
    buffer: UnsafePointer<CChar>?,
    len: Int
) -> Int32 {
    guard let stream = stream,
          let buffer = buffer,
          let context = streamContexts[stream] else {
        return -1
    }
    
    // Append data to request body
    context.requestBody.append(UnsafeBufferPointer(start: buffer, count: len))
    return 0
}

// Reads data from the stream (called by libgit2 to receive response body).
private func mtlsStreamRead(
    stream: UnsafeMutablePointer<git_smart_subtransport_stream>?,
    buffer: UnsafeMutablePointer<CChar>?,
    bufSize: Int,
    bytesRead: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let stream = stream,
          let buffer = buffer,
          let bytesRead = bytesRead,
          let context = streamContexts[stream] else {
        return -1
    }
    
    // Start the HTTP request when libgit2 begins reading the stream.
    if !context.requestStarted {
        let result = startHTTPRequest(context: context)
        if result != 0 {
            return result
        }
        context.requestStarted = true
    }
    
    let readResult = context.responseBuffer.read(into: buffer, maxCount: bufSize)
    if let error = readResult.error {
        context.error = error
        let nsError = error as NSError
        let description: String
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    description = "Connection failed: \(underlying.localizedDescription)"
                } else {
                    description = "Connection cancelled (TLS or authentication failure)"
                }
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                description = "Cannot connect to server"
            case NSURLErrorTimedOut:
                description = "Connection timed out"
            case NSURLErrorNetworkConnectionLost:
                description = "Network connection lost"
            default:
                description = nsError.localizedDescription
            }
        } else {
            description = nsError.localizedDescription
        }
        logError("Read failed: \(description)", context: "MTLSTransport")
        _ = description.withCString { cstr in
            git_error_set_str(Int32(GIT_ERROR_NET.rawValue), cstr)
        }
        return -1
    }
    
    bytesRead.pointee = readResult.bytesRead
    return 0
}

// Frees stream resources.
private func mtlsStreamFree(stream: UnsafeMutablePointer<git_smart_subtransport_stream>?) {
    guard let stream = stream else { return }
    if let context = streamContexts.removeValue(forKey: stream) {
        context.responseBuffer.finish()
        context.task = nil
    }
    stream.deallocate()
}

// Starts an HTTP request and streams response bytes into the shared buffer.
private func startHTTPRequest(context: StreamContext) -> Int32 {
    if context.subtransportContext.session == nil {
        guard let identity = MTLSTransport.shared.getClientIdentity(),
              let ca = MTLSTransport.shared.getPinnedCA() else {
            logError("No mTLS credentials configured", context: "MTLSTransport")
            return -1
        }
        
        let authDelegate = MTLSURLSessionDelegate(clientIdentity: identity, pinnedCA: ca)
        let delegate = StreamingDataDelegate(authDelegate: authDelegate)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        context.subtransportContext.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        context.subtransportContext.sessionDelegate = delegate
        logDebug("Created shared URLSession for subtransport", context: "MTLSTransport")
    }
    
    // Convert mtls+https:// to https://
    let httpsURL = context.url.replacingOccurrences(of: "mtls+https://", with: "https://")
    
    // Build the request URL based on action
    let (urlString, method, contentType, acceptType) = buildRequestParams(
        baseURL: httpsURL,
        action: context.action
    )
    
    guard let url = URL(string: urlString) else {
        logError("Invalid URL: \(urlString)", context: "MTLSTransport")
        return -1
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 300
    
    if let contentType = contentType {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    if let acceptType = acceptType {
        request.setValue(acceptType, forHTTPHeaderField: "Accept")
    }
    
    if !context.requestBody.isEmpty {
        request.httpBody = context.requestBody
    }
    
    logDebug("\(method) \(urlString) (\(context.requestBody.count) bytes)", context: "MTLSTransport")

    guard let session = context.subtransportContext.session,
          let delegate = context.subtransportContext.sessionDelegate else {
        logError("Shared URLSession was not initialized", context: "MTLSTransport")
        return -1
    }
    
    let task = session.dataTask(with: request)
    delegate.register(task: task, responseBuffer: context.responseBuffer)
    context.task = task
    task.resume()
    logDebug("Streaming request started", context: "MTLSTransport")
    
    return 0
}

// Builds HTTP request parameters based on the Git action type.
private func buildRequestParams(
    baseURL: String,
    action: git_smart_service_t
) -> (url: String, method: String, contentType: String?, acceptType: String?) {
    // Remove trailing slash from base URL
    let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    
    switch action {
    case GIT_SERVICE_UPLOADPACK_LS:
        return (
            "\(base)/info/refs?service=git-upload-pack",
            "GET",
            nil,
            "application/x-git-upload-pack-advertisement"
        )
    case GIT_SERVICE_UPLOADPACK:
        return (
            "\(base)/git-upload-pack",
            "POST",
            "application/x-git-upload-pack-request",
            "application/x-git-upload-pack-result"
        )
    case GIT_SERVICE_RECEIVEPACK_LS:
        return (
            "\(base)/info/refs?service=git-receive-pack",
            "GET",
            nil,
            "application/x-git-receive-pack-advertisement"
        )
    case GIT_SERVICE_RECEIVEPACK:
        return (
            "\(base)/git-receive-pack",
            "POST",
            "application/x-git-receive-pack-request",
            "application/x-git-receive-pack-result"
        )
    default:
        return (base, "GET", nil, nil)
    }
}

// MARK: - URL Helpers

extension MTLSTransport {
    
    // Converts an https:// URL to the mtls+https:// scheme for use with libgit2.
    // This ensures remotes are routed through our custom mTLS transport.
    public static func convertToMTLSScheme(_ urlString: String) -> String {
        if urlString.hasPrefix("https://") {
            return urlString.replacingOccurrences(of: "https://", with: "mtls+https://")
        }
        if urlString.hasPrefix("http://") {
            // Also support upgrading http to mtls+https for safety
            return urlString.replacingOccurrences(of: "http://", with: "mtls+https://")
        }
        return urlString
    }
    
    // Converts an mtls+https:// URL back to standard https:// for network requests.
    public static func convertToHTTPSScheme(_ urlString: String) -> String {
        return urlString.replacingOccurrences(of: "mtls+https://", with: "https://")
    }
}

// MARK: - Error Types

public enum MTLSTransportError: Error, LocalizedError {
    case registrationFailed(code: Int32)
    case notConfigured
    case invalidURL
    case networkError(String)
    
    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let code):
            return "Failed to register mtls+https transport (code: \(code))"
        case .notConfigured:
            return "mTLS transport not configured. Call MTLSTransport.shared.configure() first."
        case .invalidURL:
            return "Invalid URL for mTLS transport"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}
