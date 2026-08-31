import Foundation
import CryptoKit
import Security

public enum LFSError: Error {
    case invalidFileURL
    case fileReadError(String)
    case networkError(String)
    case serverError(Int, String)
    case invalidResponse(String)
    case authenticationRequired
    case uploadFailed(String)
}

public struct LFSPointer {
    public let version: String = "https://git-lfs.github.com/spec/v1"
    public let oid: String
    public let size: Int64

    public var content: String {
        [
            "version \(version)",
            "oid sha256:\(oid)",
            "size \(size)"
        ].joined(separator: "\n")
    }

    public init(oid: String, size: Int64) {
        self.oid = oid
        self.size = size
    }
}

struct LFSBatchRequest: Codable {
    let operation: String
    let transfers: [String]
    let objects: [LFSObject]
    
    struct LFSObject: Codable {
        let oid: String
        let size: Int64
    }
}

struct LFSBatchResponse: Codable {
    let objects: [LFSObjectResponse]
    
    struct LFSObjectResponse: Codable {
        let oid: String
        let size: Int64
        let actions: Actions?
        let error: ErrorInfo?
        
        struct Actions: Codable {
            let upload: UploadAction?
            let download: DownloadAction?
            
            struct UploadAction: Codable {
                let href: String
                let header: [String: String]?
            }
            
            struct DownloadAction: Codable {
                let href: String
                let header: [String: String]?
            }
        }
        
        struct ErrorInfo: Codable {
            let code: Int
            let message: String
        }
    }
}

public final class GitLFS: NSObject {
    private let serverURL: String
    private let authToken: String?
    private let username: String?
    private let password: String?
    private let clientIdentity: SecIdentity?
    private let pinnedCA: SecCertificate?
    // Session delegate is a separate object because URLSession retains its
    // delegate until invalidation; using `self` would leak the client.
    private let authDelegate: MTLSURLSessionAuthDelegate
    // One long-lived session per client so concurrent timeline downloads
    // do not create/invalidate sessions that CFNetwork still holds.
    private let session: URLSession
    private let uploadTaskLock = NSLock()
    private var activeUploadTasks: [ObjectIdentifier: URLSessionTask] = [:]
    
    // Stores transport configuration so tests and app code can control URL loading behavior consistently.
    public init(
        serverURL: String,
        authToken: String? = nil,
        clientIdentity: SecIdentity? = nil,
        pinnedCA: SecCertificate? = nil,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        var cleanURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        var extractedUsername: String?
        var extractedPassword: String?
        
        if let url = URL(string: cleanURL),
           let userInfo = url.user {
            extractedUsername = userInfo
            extractedPassword = url.password
            
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.user = nil
            components?.password = nil
            if let cleanedURL = components?.url?.absoluteString {
                cleanURL = cleanedURL.hasSuffix("/") ? String(cleanedURL.dropLast()) : cleanedURL
                print("LFS: Extracted credentials from URL, username: \(userInfo)")
            }
        }
        
        self.serverURL = cleanURL
        self.authToken = authToken
        self.username = extractedUsername
        self.password = extractedPassword
        self.clientIdentity = clientIdentity
        self.pinnedCA = pinnedCA
        self.authDelegate = MTLSURLSessionAuthDelegate(
            clientIdentity: clientIdentity,
            pinnedCA: pinnedCA
        )
        // Copy so caller-owned configs (including test protocolClasses) are
        // not mutated; disable URLCache because LFS blobs already go through
        // ImageDiskCacheManager and cache writes raced session teardown.
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        self.session = URLSession(
            configuration: configuration,
            delegate: self.authDelegate,
            delegateQueue: nil
        )
        
        super.init()
        
        if username != nil {
            print("LFS: Basic authentication enabled")
        }
    }

    // Releases the shared session when the client is discarded so the
    // auth delegate is not retained for the rest of the process lifetime.
    deinit {
        session.finishTasksAndInvalidate()
    }

    // Cancels in-flight PUT tasks so sync abort stops uploads without
    // tearing down the shared session used by concurrent downloads.
    public func cancelActiveUpload() {
        print("LFS: Cancelling active upload session")
        uploadTaskLock.lock()
        let tasks = Array(activeUploadTasks.values)
        activeUploadTasks.removeAll()
        uploadTaskLock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    // Records an upload task so cancelActiveUpload can target PUTs only.
    private func trackUpload(_ task: URLSessionTask) {
        uploadTaskLock.lock()
        activeUploadTasks[ObjectIdentifier(task)] = task
        uploadTaskLock.unlock()
    }

    // Drops a finished or cancelled upload so the cancel set stays accurate.
    private func untrackUpload(_ task: URLSessionTask) {
        uploadTaskLock.lock()
        activeUploadTasks.removeValue(forKey: ObjectIdentifier(task))
        uploadTaskLock.unlock()
    }
    
    @available(iOS 13.0, macOS 10.15, *)
    public func calculateHash(for fileURL: URL) throws -> (oid: String, size: Int64) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LFSError.invalidFileURL
        }
        
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            throw LFSError.fileReadError("Could not open file for reading")
        }
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        var totalSize: Int64 = 0
        
        while autoreleasepool(invoking: {
            if #available(iOS 13.4, macOS 10.15.4, *), let data = try? fileHandle.read(upToCount: bufferSize), !data.isEmpty {
                hasher.update(data: data)
                totalSize += Int64(data.count)
                return true
            }
            return false
        }) {}
        
        let digest = hasher.finalize()
        let oid = digest.map { String(format: "%02x", $0) }.joined()
        
        return (oid: oid, size: totalSize)
    }
    
    @available(iOS 13.0, macOS 10.15, *)
    public func calculateHash(for data: Data) -> (oid: String, size: Int64) {
        let digest = SHA256.hash(data: data)
        let oid = digest.map { String(format: "%02x", $0) }.joined()
        return (oid: oid, size: Int64(data.count))
    }
    
    public func createPointer(oid: String, size: Int64) -> LFSPointer {
        LFSPointer(oid: oid, size: size)
    }
    
    @available(iOS 13.0, macOS 10.15, *)
    public func uploadFile(at fileURL: URL) async throws -> LFSPointer {
        let (oid, size) = try calculateHash(for: fileURL)
        
        guard let fileData = try? Data(contentsOf: fileURL) else {
            throw LFSError.fileReadError("Could not read file data")
        }
        
        try await upload(data: fileData, oid: oid, size: size, progressHandler: nil)
        
        return LFSPointer(oid: oid, size: size)
    }
    
    @available(iOS 13.0, macOS 10.15, *)
    public func uploadData(_ data: Data, progressHandler: ((Int64, Int64) -> Void)? = nil) async throws -> LFSPointer {
        print("LFS: Starting upload of \(data.count) bytes")
        let (oid, size) = calculateHash(for: data)
        print("LFS: Calculated SHA-256: \(oid)")
        try await upload(data: data, oid: oid, size: size, progressHandler: progressHandler)
        print("LFS: Upload complete for OID: \(oid)")
        return LFSPointer(oid: oid, size: size)
    }

    // Streams an opaque PUT body so callers can supply ciphertext
    // without LibGit2 knowing how those bytes were produced.
    @available(iOS 13.0, macOS 10.15, *)
    public func uploadStream(
        oid: String,
        size: Int64,
        progressHandler: ((Int64, Int64) -> Void)? = nil,
        makeBody: @escaping () throws -> InputStream
    ) async throws -> LFSPointer {
        print("LFS: Starting streamed upload for OID: \(oid)")

        let uploadInfo = try await requestBatchUpload(oid: oid, size: size)

        guard let uploadAction = uploadInfo.actions?.upload else {
            if let error = uploadInfo.error {
                print("LFS: Server returned error: \(error.message) (code: \(error.code))")
                throw LFSError.serverError(error.code, error.message)
            }
            print("LFS: No upload action required (object may already exist)")
            return LFSPointer(oid: oid, size: size)
        }

        guard let uploadURL = URL(string: uploadAction.href) else {
            throw LFSError.invalidResponse("Invalid upload URL")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"

        if let headers = uploadAction.header {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(size)", forHTTPHeaderField: "Content-Length")

        if let username = username, let password = password {
            let credentials = "\(username):\(password)"
            if let credentialsData = credentials.data(using: .utf8) {
                let base64Credentials = credentialsData.base64EncodedString()
                request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
            }
        }

        let delegate = StreamUploadDelegate(
            progressHandler: progressHandler,
            clientIdentity: clientIdentity,
            pinnedCA: pinnedCA,
            bodyStreamFactory: makeBody
        )

        var uploadTask: URLSessionTask?
        defer {
            if let uploadTask {
                untrackUpload(uploadTask)
            }
        }

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Swift.Error>) in
            delegate.completion = { error, response in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let response else {
                    continuation.resume(throwing: LFSError.networkError("Invalid response type"))
                    return
                }
                continuation.resume(returning: response)
            }

            let task = self.session.uploadTask(withStreamedRequest: request)
            task.delegate = delegate
            uploadTask = task
            self.trackUpload(task)
            task.resume()
        }

        guard (200...299).contains(response.statusCode) else {
            throw LFSError.uploadFailed("Upload failed with status code: \(response.statusCode)")
        }

        print("LFS: Streaming upload complete for OID: \(oid)")
        return LFSPointer(oid: oid, size: size)
    }
    
    // Performs one LFS upload transaction so object registration and binary transfer stay atomic per object.
    @available(iOS 13.0, macOS 10.15, *)
    private func upload(
        data: Data,
        oid: String,
        size: Int64,
        progressHandler: ((Int64, Int64) -> Void)?
    ) async throws {
        print("LFS: Requesting batch upload for OID: \(oid)")
        let uploadInfo = try await requestBatchUpload(oid: oid, size: size)
        
        guard let uploadAction = uploadInfo.actions?.upload else {
            if let error = uploadInfo.error {
                print("LFS: Server returned error: \(error.message) (code: \(error.code))")
                throw LFSError.serverError(error.code, error.message)
            }
            print("LFS: No upload action required (object may already exist)")
            return
        }
        
        guard let uploadURL = URL(string: uploadAction.href) else {
            print("LFS: Invalid upload URL: \(uploadAction.href)")
            throw LFSError.invalidResponse("Invalid upload URL")
        }
        
        print("LFS: Uploading to: \(uploadURL)")
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        
        if let headers = uploadAction.header {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        
        if let username = username, let password = password {
            let credentials = "\(username):\(password)"
            if let credentialsData = credentials.data(using: .utf8) {
                let base64Credentials = credentialsData.base64EncodedString()
                print("LFS: Adding basic authentication to upload request")
                request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
            }
        }
        
        print("LFS: Sending PUT request with \(data.count) bytes...")
        
        let delegate = UploadDelegate(
            progressHandler: progressHandler,
            clientIdentity: clientIdentity,
            pinnedCA: pinnedCA
        )

        var uploadTask: URLSessionTask?
        defer {
            if let uploadTask {
                untrackUpload(uploadTask)
            }
        }
        
        let (_, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { continuation in
            let task = self.session.uploadTask(with: request, from: data) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response))
                }
            }
            task.delegate = delegate
            uploadTask = task
            self.trackUpload(task)
            task.resume()
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("LFS: Invalid response type")
            throw LFSError.networkError("Invalid response type")
        }
        
        print("LFS: Upload response status: \(httpResponse.statusCode)")
        guard (200...299).contains(httpResponse.statusCode) else {
            print("LFS: Upload failed with status code: \(httpResponse.statusCode)")
            throw LFSError.uploadFailed("Upload failed with status code: \(httpResponse.statusCode)")
        }
        
        print("LFS: Upload successful")
    }
    
    // Downloads one LFS object through this instance's URL loading
    // configuration so mocked transports are honored. Emits a single
    // compact log line on success with status, byte count, TTFB, and
    // total elapsed time.
    @available(iOS 13.0, macOS 10.15, *)
    public func downloadData(oid: String, size: Int64, progressHandler: ((Int64, Int64) -> Void)? = nil) async throws -> Data {
        let downloadInfo = try await requestBatchDownload(oid: oid, size: size)

        guard let downloadAction = downloadInfo.actions?.download else {
            if let error = downloadInfo.error {
                print("LFS: Download failed oid=\(oid)"
                    + " error=\"\(error.message)\" code=\(error.code)")
                throw LFSError.serverError(error.code, error.message)
            }
            print("LFS: Download failed oid=\(oid)"
                + " error=\"No download action available\"")
            throw LFSError.invalidResponse("No download action available")
        }

        guard let downloadURL = URL(string: downloadAction.href) else {
            print("LFS: Download failed oid=\(oid)"
                + " error=\"Invalid download URL\"")
            throw LFSError.invalidResponse("Invalid download URL")
        }

        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"

        if let headers = downloadAction.header {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let username = username, let password = password {
            let credentials = "\(username):\(password)"
            if let credentialsData = credentials.data(using: .utf8) {
                let base64Credentials = credentialsData.base64EncodedString()
                request.setValue(
                    "Basic \(base64Credentials)",
                    forHTTPHeaderField: "Authorization"
                )
            }
        }

        let delegate = DownloadDelegate(
            progressHandler: progressHandler,
            clientIdentity: clientIdentity,
            pinnedCA: pinnedCA
        )

        let requestStart = DispatchTime.now()

        let (data, response): (Data, URLResponse?) =
            try await withCheckedThrowingContinuation { continuation in
                let task = self.session.dataTask(with: request) {
                    data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(
                            returning: (data ?? Data(), response)
                        )
                    }
                }
                task.delegate = delegate
                task.resume()
            }

        let totalMs = Int(
            (DispatchTime.now().uptimeNanoseconds
                - requestStart.uptimeNanoseconds) / 1_000_000
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            print("LFS: Download failed oid=\(oid)"
                + " error=\"Invalid response type\"")
            throw LFSError.networkError("Invalid response type")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            print("LFS: Download failed oid=\(oid)"
                + " status=\(httpResponse.statusCode)")
            throw LFSError.uploadFailed(
                "Download failed with status code:"
                    + " \(httpResponse.statusCode)"
            )
        }

        let ttfb = delegate.ttfbMs.map { " ttfb=\($0)ms" } ?? ""
        let href = downloadAction.href
        let displayURL = href.count > 72
            ? href.prefix(72) + "..." : href
        print("LFS: Download oid=\(oid)"
            + " status=\(httpResponse.statusCode)"
            + " bytes=\(data.count)"
            + "\(ttfb) total=\(totalMs)ms"
            + " url=\(displayURL)")
        return data
    }
    
    // Requests download actions using the same session policy as data
    // transfers to keep auth and protocol interception aligned. Quiet
    // on success; only logs on failure to keep download output compact.
    @available(iOS 13.0, macOS 10.15, *)
    private func requestBatchDownload(
        oid: String, size: Int64
    ) async throws -> LFSBatchResponse.LFSObjectResponse {
        let batchURL = URL(string: "\(serverURL)/objects/batch")!

        let batchRequest = LFSBatchRequest(
            operation: "download",
            transfers: ["basic"],
            objects: [LFSBatchRequest.LFSObject(oid: oid, size: size)]
        )

        var request = URLRequest(url: batchURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/vnd.git-lfs+json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/vnd.git-lfs+json",
            forHTTPHeaderField: "Accept"
        )

        if let authToken = authToken {
            request.setValue(
                "Bearer \(authToken)",
                forHTTPHeaderField: "Authorization"
            )
        } else if let username = username, let password = password {
            let credentials = "\(username):\(password)"
            if let credentialsData = credentials.data(using: .utf8) {
                let base64Credentials =
                    credentialsData.base64EncodedString()
                request.setValue(
                    "Basic \(base64Credentials)",
                    forHTTPHeaderField: "Authorization"
                )
            }
        }

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(batchRequest)

        let (data, response): (Data, URLResponse?) =
            try await withCheckedThrowingContinuation { continuation in
                let task = self.session.dataTask(with: request) {
                    data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(
                            returning: (data ?? Data(), response)
                        )
                    }
                }
                task.resume()
            }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("LFS: Batch download failed oid=\(oid)"
                + " error=\"Invalid response type\"")
            throw LFSError.networkError("Invalid response type")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage =
                String(data: data, encoding: .utf8) ?? "Unknown error"
            print("LFS: Batch download failed oid=\(oid)"
                + " status=\(httpResponse.statusCode)"
                + " error=\"\(errorMessage)\"")
            throw LFSError.serverError(
                httpResponse.statusCode, errorMessage
            )
        }

        let decoder = JSONDecoder()
        let batchResponse = try decoder.decode(
            LFSBatchResponse.self, from: data
        )

        guard let object = batchResponse.objects.first else {
            print("LFS: Batch download failed oid=\(oid)"
                + " error=\"No objects in batch response\"")
            throw LFSError.invalidResponse(
                "No objects in batch response"
            )
        }

        return object
    }
    
    // Requests upload actions with the same URL loading stack used by uploads so mocks and auth behavior remain consistent.
    @available(iOS 13.0, macOS 10.15, *)
    private func requestBatchUpload(oid: String, size: Int64) async throws -> LFSBatchResponse.LFSObjectResponse {
        let batchURL = URL(string: "\(serverURL)/objects/batch")!
        print("LFS: Requesting batch upload from: \(batchURL)")
        
        let batchRequest = LFSBatchRequest(
            operation: "upload",
            transfers: ["basic"],
            objects: [LFSBatchRequest.LFSObject(oid: oid, size: size)]
        )
        
        var request = URLRequest(url: batchURL)
        request.httpMethod = "POST"
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Accept")
        
        if let authToken = authToken {
            print("LFS: Using bearer token authentication")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        } else if let username = username, let password = password {
            let credentials = "\(username):\(password)"
            if let credentialsData = credentials.data(using: .utf8) {
                let base64Credentials = credentialsData.base64EncodedString()
                print("LFS: Using basic authentication for user: \(username)")
                request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
            }
        }
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(batchRequest)
        
        print("LFS: Sending batch request...")
        let (data, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { continuation in
            let task = self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response))
                }
            }
            task.resume()
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("LFS: Invalid response type from batch request")
            throw LFSError.networkError("Invalid response type")
        }
        
        print("LFS: Batch response status: \(httpResponse.statusCode)")
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("LFS: Batch request failed: \(errorMessage)")
            throw LFSError.serverError(httpResponse.statusCode, errorMessage)
        }
        
        let decoder = JSONDecoder()
        let batchResponse = try decoder.decode(LFSBatchResponse.self, from: data)
        
        guard let object = batchResponse.objects.first else {
            print("LFS: No objects in batch response")
            throw LFSError.invalidResponse("No objects in batch response")
        }
        
        print("LFS: Batch request successful")
        return object
    }
}

// Bridges streamed URLSession uploads to deterministic body stream creation and progress/completion callbacks.
private final class StreamUploadDelegate: MTLSURLSessionAuthDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let progressHandler: ((Int64, Int64) -> Void)?
    private let bodyStreamFactory: () throws -> InputStream
    private var completed = false
    private var streamFactoryError: Swift.Error?
    var completion: ((Swift.Error?, HTTPURLResponse?) -> Void)?

    // Stores callbacks used by upload tasks that provide their request body via URLSession's streamed request API.
    init(
        progressHandler: ((Int64, Int64) -> Void)?,
        clientIdentity: SecIdentity?,
        pinnedCA: SecCertificate?,
        bodyStreamFactory: @escaping () throws -> InputStream
    ) {
        self.progressHandler = progressHandler
        self.bodyStreamFactory = bodyStreamFactory
        super.init(clientIdentity: clientIdentity, pinnedCA: pinnedCA)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressHandler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        do {
            completionHandler(try bodyStreamFactory())
        } catch {
            streamFactoryError = error
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Swift.Error)?) {
        guard !completed else { return }
        completed = true
        if let error {
            completion?(error, task.response as? HTTPURLResponse)
            return
        }
        if let streamFactoryError {
            completion?(streamFactoryError, task.response as? HTTPURLResponse)
            return
        }
        completion?(nil, task.response as? HTTPURLResponse)
    }
}

private class UploadDelegate: MTLSURLSessionAuthDelegate, URLSessionTaskDelegate {
    private let progressHandler: ((Int64, Int64) -> Void)?
    
    init(progressHandler: ((Int64, Int64) -> Void)?, clientIdentity: SecIdentity?, pinnedCA: SecCertificate?) {
        self.progressHandler = progressHandler
        super.init(clientIdentity: clientIdentity, pinnedCA: pinnedCA)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressHandler?(totalBytesSent, totalBytesExpectedToSend)
    }
}

// Captures URLSession task metrics so the download path can report TTFB
// alongside total elapsed time in one compact log line.
private class DownloadDelegate: MTLSURLSessionAuthDelegate, URLSessionTaskDelegate {
    private let progressHandler: ((Int64, Int64) -> Void)?
    private(set) var ttfbMs: Int?

    init(progressHandler: ((Int64, Int64) -> Void)?, clientIdentity: SecIdentity?, pinnedCA: SecCertificate?) {
        self.progressHandler = progressHandler
        super.init(clientIdentity: clientIdentity, pinnedCA: pinnedCA)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let tx = metrics.transactionMetrics.last,
              let reqStart = tx.requestStartDate,
              let respStart = tx.responseStartDate else { return }
        ttfbMs = Int(respStart.timeIntervalSince(reqStart) * 1000)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }
}

extension Repository {
    @available(iOS 13.0, macOS 10.15, *)
    public func addLFSFile(at filePath: String, lfsClient: GitLFS) async throws -> LFSPointer {
        let fileURL = URL(fileURLWithPath: filePath)
        return try await lfsClient.uploadFile(at: fileURL)
    }
    
    @available(iOS 13.0, macOS 10.15, *)
    public func addLFSData(_ data: Data, toPath filePath: String, lfsClient: GitLFS, progressHandler: ((Int64, Int64) -> Void)? = nil) async throws -> LFSPointer {
        print("Git: Adding LFS data to path: \(filePath)")
        return try await lfsClient.uploadData(data, progressHandler: progressHandler)
    }

    // Reads repository file bytes so callers can choose decoding strategy based on content format.
    public func readFileData(at path: String) throws -> Data {
        try readBlobDataFromHead(at: path)
    }

    // Decodes repository text files as UTF-8 to avoid implicit encoding inference from Foundation.
    public func readFile(at path: String) throws -> String {
        let data = try readFileData(at: path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitError.repositoryError("Failed to decode file as UTF-8: \(path)")
        }
        return text
    }
    
    public func listFiles(in directory: String) throws -> [String] {
        try listTreeEntriesFromHead(in: directory)
    }
}
