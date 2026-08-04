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
    case invalidEncryptionMetadata
}

public struct LFSPointer {
    public let version: String = "https://git-lfs.github.com/spec/v1"
    public let oid: String
    public let size: Int64
    public let kekEpoch: Int?
    public let wrappedDEK: String?

    public var content: String {
        var lines = [
            "version \(version)",
            "oid sha256:\(oid)",
            "size \(size)"
        ]
        if let kekEpoch {
            lines.append("x-replycant-kek-epoch \(kekEpoch)")
        }
        if let wrappedDEK {
            lines.append("x-replycant-wrapped-dek \(wrappedDEK)")
        }
        return lines.joined(separator: "\n")
    }

    // Chunk size is intentionally omitted: it is a compile-time constant, not pointer metadata.
    public init(oid: String, size: Int64, kekEpoch: Int? = nil, wrappedDEK: String? = nil) {
        self.oid = oid
        self.size = size
        self.kekEpoch = kekEpoch
        self.wrappedDEK = wrappedDEK
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
    private let sessionConfiguration: URLSessionConfiguration
    private var progressHandler: ((Int64, Int64) -> Void)?
    private var uploadSession: URLSession?
    private var activeUploadTask: URLSessionTask?
    
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
        self.sessionConfiguration = sessionConfiguration
        
        super.init()
        
        if username != nil {
            print("LFS: Basic authentication enabled")
        }
    }

    // Cancels the active transfer session so higher-level sync cancellation stops network activity promptly.
    public func cancelActiveUpload() {
        print("LFS: Cancelling active upload session")
        activeUploadTask?.cancel()
        uploadSession?.invalidateAndCancel()
        activeUploadTask = nil
        uploadSession = nil
        progressHandler = nil
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
        
        try await upload(data: fileData, oid: oid, size: size)
        
        return LFSPointer(oid: oid, size: size)
    }
    
    @available(iOS 13.0, macOS 10.15, *)
    public func uploadData(_ data: Data, progressHandler: ((Int64, Int64) -> Void)? = nil) async throws -> LFSPointer {
        print("LFS: Starting upload of \(data.count) bytes")
        self.progressHandler = progressHandler
        let (oid, size) = calculateHash(for: data)
        print("LFS: Calculated SHA-256: \(oid)")
        try await upload(data: data, oid: oid, size: size)
        print("LFS: Upload complete for OID: \(oid)")
        self.progressHandler = nil
        return LFSPointer(oid: oid, size: size)
    }

    // Streams deterministic chunk encryption directly into the PUT body so very large uploads avoid full ciphertext buffering.
    @available(iOS 13.0, macOS 10.15, *)
    public func uploadFileEncrypting(
        at fileURL: URL,
        dek: Data,
        oid: String,
        size: Int64,
        progressHandler: ((Int64, Int64) -> Void)? = nil
    ) async throws -> LFSPointer {
        print("LFS: Starting streaming encrypted upload for OID: \(oid)")
        self.progressHandler = progressHandler

        let uploadInfo = try await requestBatchUpload(oid: oid, size: size)

        guard let uploadAction = uploadInfo.actions?.upload else {
            if let error = uploadInfo.error {
                print("LFS: Server returned error: \(error.message) (code: \(error.code))")
                throw LFSError.serverError(error.code, error.message)
            }
            print("LFS: No upload action required (object may already exist)")
            self.progressHandler = nil
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
            pinnedCA: pinnedCA
        ) {
            try EncryptingInputStream(fileURL: fileURL, dek: dek)
        }
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        self.uploadSession = session

        defer {
            session.finishTasksAndInvalidate()
            self.activeUploadTask = nil
            self.uploadSession = nil
            self.progressHandler = nil
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

            let task = session.uploadTask(withStreamedRequest: request)
            self.activeUploadTask = task
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
    private func upload(data: Data, oid: String, size: Int64) async throws {
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
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        self.uploadSession = session
        
        defer {
            session.finishTasksAndInvalidate()
            self.activeUploadTask = nil
            self.uploadSession = nil
        }
        
        let (_, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, from: data) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response))
                }
            }
            self.activeUploadTask = task
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
        self.progressHandler = progressHandler

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
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.uploadSession = session

        defer {
            session.finishTasksAndInvalidate()
            self.uploadSession = nil
            self.progressHandler = nil
        }

        let requestStart = DispatchTime.now()

        let (data, response): (Data, URLResponse?) =
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) {
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

        let delegate = MTLSURLSessionAuthDelegate(clientIdentity: clientIdentity, pinnedCA: pinnedCA)
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse?) =
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) {
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
        let delegate = MTLSURLSessionAuthDelegate(clientIdentity: clientIdentity, pinnedCA: pinnedCA)
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
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

// Streams encrypted chunks from a source file so URLSession can upload ciphertext without buffering whole objects in memory.
private final class EncryptingInputStream: InputStream {
    private static let chunkSize = 65_536

    private let fileURL: URL
    private let symmetricKey: SymmetricKey
    private let totalChunks: Int
    private var fileHandle: FileHandle?
    private var chunkIndex = 0
    private var encryptedBuffer = Data()
    private var encryptedBufferOffset = 0
    private var currentStatus: Stream.Status = .notOpen
    private var currentError: Swift.Error?
    private weak var _delegate: (any StreamDelegate)?

    // Initializes deterministic chunk encryption state for one upload request body stream.
    // totalChunks is derived from file size so the last-chunk AAD flag is known before reading.
    init(fileURL: URL, dek: Data) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LFSError.invalidFileURL
        }
        guard dek.count == 32 else {
            throw LFSError.invalidEncryptionMetadata
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let plaintextSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let totalChunks = plaintextSize == 0
            ? 0
            : Int((plaintextSize + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize))

        self.fileURL = fileURL
        self.symmetricKey = SymmetricKey(data: dek)
        self.totalChunks = totalChunks
        super.init(data: Data())
    }

    override var delegate: (any StreamDelegate)? {
        get { _delegate }
        set { _delegate = newValue }
    }

    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override var hasBytesAvailable: Bool {
        switch currentStatus {
        case .open:
            return true
        case .atEnd:
            return false
        default:
            return false
        }
    }

    override var streamStatus: Stream.Status {
        currentStatus
    }

    override var streamError: Swift.Error? {
        currentError
    }

    override func open() {
        guard currentStatus == .notOpen else { return }
        do {
            fileHandle = try FileHandle(forReadingFrom: fileURL)
            chunkIndex = 0
            encryptedBuffer.removeAll(keepingCapacity: true)
            encryptedBufferOffset = 0
            currentStatus = .open
        } catch {
            currentError = error
            currentStatus = .error
        }
    }

    override func close() {
        try? fileHandle?.close()
        fileHandle = nil
        encryptedBuffer.removeAll(keepingCapacity: false)
        encryptedBufferOffset = 0
        currentStatus = .closed
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard currentStatus == .open else {
            return currentStatus == .atEnd ? 0 : -1
        }
        guard len > 0 else { return 0 }

        if encryptedBufferOffset >= encryptedBuffer.count {
            do {
                let didLoadChunk = try loadNextEncryptedChunk()
                if !didLoadChunk {
                    currentStatus = .atEnd
                    return 0
                }
            } catch {
                currentError = error
                currentStatus = .error
                return -1
            }
        }

        let available = encryptedBuffer.count - encryptedBufferOffset
        let toCopy = min(available, len)
        guard toCopy > 0 else {
            currentStatus = .atEnd
            return 0
        }

        encryptedBuffer.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(buffer, baseAddress.advanced(by: encryptedBufferOffset), toCopy)
        }
        encryptedBufferOffset += toCopy

        if encryptedBufferOffset >= encryptedBuffer.count {
            encryptedBuffer.removeAll(keepingCapacity: true)
            encryptedBufferOffset = 0
        }

        return toCopy
    }

    // Encrypts one plaintext chunk and stages ciphertext||tag bytes for subsequent stream reads.
    private func loadNextEncryptedChunk() throws -> Bool {
        guard let fileHandle else {
            throw LFSError.fileReadError("File handle is not open")
        }
        guard chunkIndex < totalChunks else {
            return false
        }

        let plaintextChunk: Data
        if #available(iOS 13.4, macOS 10.15.4, *) {
            plaintextChunk = try fileHandle.read(upToCount: Self.chunkSize) ?? Data()
        } else {
            plaintextChunk = fileHandle.readData(ofLength: Self.chunkSize)
        }

        if plaintextChunk.isEmpty {
            throw LFSError.fileReadError("Unexpected early EOF while encrypting chunk \(chunkIndex)")
        }

        let nonce = try LFSChunkFraming.nonceForChunk(index: chunkIndex)
        let aad = try LFSChunkFraming.chunkAAD(index: chunkIndex, isLast: chunkIndex == totalChunks - 1)
        let sealed = try AES.GCM.seal(plaintextChunk, using: symmetricKey, nonce: nonce, authenticating: aad)
        encryptedBuffer.removeAll(keepingCapacity: true)
        encryptedBuffer.append(sealed.ciphertext)
        encryptedBuffer.append(sealed.tag)
        encryptedBufferOffset = 0
        chunkIndex += 1
        return true
    }
}

// Shared LFS chunk framing helpers so streaming upload and repository decrypt stay byte-identical.
private enum LFSChunkFraming {
    private static let chunkAADPrefix = Data("replycant-lfs-chunk-v1".utf8)
    private static let dekWrapAADPrefix = Data("replycant-dek-wrap-v1".utf8)

    // Derives the 12-byte AES-GCM nonce for chunk index so encryptors never place an attacker-controlled nonce on the wire.
    static func nonceForChunk(index: Int) throws -> AES.GCM.Nonce {
        var bytes = Data(repeating: 0, count: 12)
        let value = UInt64(index).bigEndian
        withUnsafeBytes(of: value) { rawBuffer in
            bytes.replaceSubrange(4..<12, with: rawBuffer)
        }
        return try AES.GCM.Nonce(data: bytes)
    }

    // Binds each seal to its index and last-chunk status so reorder and truncation fail authentication.
    static func chunkAAD(index: Int, isLast: Bool) throws -> Data {
        var aad = Data()
        aad.append(chunkAADPrefix)
        var value = UInt64(index).bigEndian
        withUnsafeBytes(of: &value) { rawBuffer in
            aad.append(contentsOf: rawBuffer)
        }
        aad.append(isLast ? 1 : 0)
        return aad
    }

    // Binds wrapped DEKs to kek-epoch so pointer metadata cannot move across epochs.
    static func dekWrapAAD(kekEpoch: Int) throws -> Data {
        var aad = Data()
        aad.append(dekWrapAADPrefix)
        var value = UInt64(kekEpoch).bigEndian
        withUnsafeBytes(of: &value) { rawBuffer in
            aad.append(contentsOf: rawBuffer)
        }
        return aad
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

    // Uploads one source file with on-the-fly chunk encryption so repository writes can avoid large in-memory ciphertext blobs.
    @available(iOS 13.0, macOS 10.15, *)
    public func addLFSFileEncrypting(
        at fileURL: URL,
        dek: Data,
        oid: String,
        size: Int64,
        toPath filePath: String,
        lfsClient: GitLFS,
        progressHandler: ((Int64, Int64) -> Void)? = nil
    ) async throws -> LFSPointer {
        print("Git: Adding encrypted LFS file to path: \(filePath)")
        return try await lfsClient.uploadFileEncrypting(
            at: fileURL,
            dek: dek,
            oid: oid,
            size: size,
            progressHandler: progressHandler
        )
    }
    
    @available(iOS 13.0, macOS 10.15, *)
    // Loads pointer metadata and decrypts chunked binary payloads, rejecting plaintext pointers under strict encryption policy.
    public func loadLFSData(from filePath: String, lfsClient: GitLFS) async throws -> Data {
        let pointerContent = try readFile(at: filePath)
        
        // Parse pointer into core and optional encryption metadata.
        let metadata = parseLFSPointer(pointerContent)
        let lfsOid = metadata.oid
        let lfsSize = metadata.size
        guard !lfsOid.isEmpty, lfsSize > 0 else {
            throw GitError.repositoryError("Invalid LFS pointer file")
        }

        let downloaded = try await lfsClient.downloadData(oid: lfsOid, size: lfsSize)
        guard let epoch = metadata.kekEpoch,
              let wrappedDEK = metadata.wrappedDEK else {
            throw LFSError.invalidEncryptionMetadata
        }

        let kek = try loadKEK(forEpoch: epoch)
        let dek = try unwrapDEK(base64WrappedDEK: wrappedDEK, kek: kek, kekEpoch: epoch)
        return try decryptChunkedBinary(ciphertext: downloaded, dek: dek)
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

    // Parses standard and custom x-replycant pointer fields so encrypted blobs can be conditionally decrypted.
    private func parseLFSPointer(_ pointerContent: String) -> LFSPointer {
        let lines = pointerContent.components(separatedBy: .newlines)
        var oid: String?
        var size: Int64?
        var kekEpoch: Int?
        var wrappedDEK: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("oid sha256:") {
                oid = String(trimmed.dropFirst("oid sha256:".count))
            } else if trimmed.hasPrefix("size ") {
                size = Int64(trimmed.dropFirst("size ".count))
            } else if trimmed.hasPrefix("x-replycant-kek-epoch ") {
                kekEpoch = Int(trimmed.dropFirst("x-replycant-kek-epoch ".count))
            } else if trimmed.hasPrefix("x-replycant-wrapped-dek ") {
                wrappedDEK = String(trimmed.dropFirst("x-replycant-wrapped-dek ".count))
            }
        }

        return LFSPointer(oid: oid ?? "", size: size ?? 0, kekEpoch: kekEpoch, wrappedDEK: wrappedDEK)
    }

    // Loads an epoch KEK directly from repository files so LibGit2 can decrypt binary blobs without app-layer types.
    private func loadKEK(forEpoch epoch: Int) throws -> Data {
        let identity = try loadAgePrivateKey()
        let path = "encryption/epochs/\(epoch).age"
        let encrypted = try readFile(at: path)
        return try decryptAgeEnvelope(Data(encrypted.utf8), identity: identity)
    }

    // Retrieves the locally stored Curve25519 private key needed to unwrap KEK epoch files in pointer decryption.
    private func loadAgePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "com.replycant.iosapp.age.private",
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            throw LFSError.invalidEncryptionMetadata
        }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    // Unwraps the per-object DEK from pointer metadata using the KEK for the referenced epoch.
    private func unwrapDEK(base64WrappedDEK: String, kek: Data, kekEpoch: Int) throws -> Data {
        guard let wrapped = Data(base64Encoded: base64WrappedDEK), kek.count == 32, kekEpoch >= 1 else {
            throw LFSError.invalidEncryptionMetadata
        }
        let key = SymmetricKey(data: kek)
        let box = try AES.GCM.SealedBox(combined: wrapped)
        let aad = try Self.dekWrapAAD(kekEpoch: kekEpoch)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    // Decrypts per-chunk AES-GCM content with index-derived nonces and AAD so reorder/truncation fail.
    private func decryptChunkedBinary(ciphertext: Data, dek: Data) throws -> Data {
        guard dek.count == 32 else {
            throw LFSError.invalidEncryptionMetadata
        }
        if ciphertext.isEmpty {
            return Data()
        }
        let key = SymmetricKey(data: dek)
        let chunkSize = 65_536
        let chunkOverhead = 16
        let fullChunk = chunkSize + chunkOverhead
        var output = Data()
        var offset = 0
        var chunkIndex = 0
        while offset < ciphertext.count {
            let remaining = ciphertext.count - offset
            let currentChunk = min(remaining, fullChunk)
            guard currentChunk >= chunkOverhead else {
                throw LFSError.invalidEncryptionMetadata
            }
            let isLast = offset + currentChunk == ciphertext.count
            let encData = ciphertext.subdata(in: offset..<(offset + currentChunk - 16))
            let tagData = ciphertext.subdata(in: (offset + currentChunk - 16)..<(offset + currentChunk))
            let nonce = try LFSChunkFraming.nonceForChunk(index: chunkIndex)
            let aad = try LFSChunkFraming.chunkAAD(index: chunkIndex, isLast: isLast)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encData, tag: tagData)
            output.append(try AES.GCM.open(box, using: key, authenticating: aad))
            offset += currentChunk
            chunkIndex += 1
        }
        return output
    }

    // Binds wrapped DEKs to kek-epoch so pointer metadata cannot move across epochs.
    private static func dekWrapAAD(kekEpoch: Int) throws -> Data {
        try LFSChunkFraming.dekWrapAAD(kekEpoch: kekEpoch)
    }

    // Decrypts the custom age-style envelope used for KEK epochs so pointer decryption can access the raw KEK.
    private func decryptAgeEnvelope(_ ciphertext: Data, identity: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard let text = String(data: ciphertext, encoding: .utf8) else {
            throw LFSError.invalidEncryptionMetadata
        }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.first == "age-encryption.org/v1" else {
            throw LFSError.invalidEncryptionMetadata
        }

        var wrappedLines: [String] = []
        var payload: Data?
        for line in lines.dropFirst() {
            if line.hasPrefix("-> X25519 ") {
                wrappedLines.append(line)
            } else if line.hasPrefix("payload ") {
                payload = Data(base64Encoded: String(line.dropFirst("payload ".count)))
            }
        }
        guard let payload else {
            throw LFSError.invalidEncryptionMetadata
        }

        let wrapSalt = Data("replycant-age-wrap-salt".utf8)
        let wrapInfo = Data("replycant-age-wrap-info".utf8)
        var fileKeyData: Data?
        for line in wrappedLines {
            let body = String(line.dropFirst("-> X25519 ".count))
            let components = body.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count == 2,
                  let ephData = Data(base64Encoded: String(components[0])),
                  let wrappedData = Data(base64Encoded: String(components[1])) else {
                continue
            }
            let eph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephData)
            let shared = try identity.sharedSecretFromKeyAgreement(with: eph)
            let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: wrapSalt, sharedInfo: wrapInfo, outputByteCount: 32)
            if let sealed = try? ChaChaPoly.SealedBox(combined: wrappedData),
               let unwrapped = try? ChaChaPoly.open(sealed, using: wrapKey),
               unwrapped.count == 32 {
                fileKeyData = unwrapped
                break
            }
        }

        guard let fileKeyData else {
            throw LFSError.invalidEncryptionMetadata
        }

        let payloadBox = try ChaChaPoly.SealedBox(combined: payload)
        let fileKey = SymmetricKey(data: fileKeyData)
        return try ChaChaPoly.open(payloadBox, using: fileKey)
    }
}

