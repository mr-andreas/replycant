import Foundation
import CryptoKit
import Testing
import LibGit2

// Serves in-memory LFS batch and download responses for one isolated host
// so shared-session tests can exercise concurrent GitLFS use without a
// real network or colliding with other URLProtocol stubs.
final class SharedSessionLFSURLProtocol: URLProtocol {
    static let host = "shared-session-lfs.local"

    private static let lock = NSLock()
    private static var dataByOID: [String: Data] = [:]
    private static var downloadDelay: TimeInterval = 0

    private let stateLock = NSLock()
    private var stopped = false

    // Replaces the in-memory object map and download delay between tests.
    static func reset(dataByOID: [String: Data] = [:], downloadDelay: TimeInterval = 0) {
        lock.lock()
        self.dataByOID = dataByOID
        self.downloadDelay = downloadDelay
        lock.unlock()
    }

    // Restricts interception to this suite's synthetic LFS host.
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    // Reuses the same request instance because rewriting is unnecessary.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // Serves batch immediately and optionally delays object downloads so
    // cancellation can race with in-flight GETs.
    override func startLoading() {
        guard let url = request.url else {
            send(status: 400, body: Data())
            return
        }

        if url.path.hasSuffix("/objects/batch"), request.httpMethod == "POST" {
            handleBatchRequest()
            return
        }

        if url.path.hasPrefix("/lfs/download/") {
            let oid = String(url.path.dropFirst("/lfs/download/".count))
            Self.lock.lock()
            let data = Self.dataByOID[oid]
            let delay = Self.downloadDelay
            Self.lock.unlock()

            let serveDownload = { [weak self] in
                guard let self else { return }
                if let data {
                    self.send(status: 200, body: data)
                } else {
                    self.send(status: 404, body: Data())
                }
            }

            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: serveDownload)
            } else {
                serveDownload()
            }
            return
        }

        send(status: 404, body: Data())
    }

    // Prevents a delayed download from completing after URLSession cancelled it.
    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    // Returns a Git LFS batch response for the requested object.
    private func handleBatchRequest() {
        guard
            let body = request.httpBody ?? readBody(from: request.httpBodyStream),
            let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let objects = payload["objects"] as? [[String: Any]],
            let object = objects.first,
            let oid = object["oid"] as? String,
            let size = object["size"] as? NSNumber
        else {
            send(status: 400, body: Data())
            return
        }

        Self.lock.lock()
        let found = Self.dataByOID[oid] != nil
        Self.lock.unlock()

        let responseObject: [String: Any]
        if found {
            responseObject = [
                "oid": oid,
                "size": size.int64Value,
                "actions": [
                    "download": [
                        "href": "https://\(Self.host)/lfs/download/\(oid)",
                        "header": [:]
                    ]
                ]
            ]
        } else {
            responseObject = [
                "oid": oid,
                "size": size.int64Value,
                "error": [
                    "code": 404,
                    "message": "Object not found"
                ]
            ]
        }

        let response: [String: Any] = ["objects": [responseObject]]
        let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        send(status: 200, body: data, contentType: "application/vnd.git-lfs+json")
    }

    // Reads streamed request bodies so batch payload parsing stays reliable.
    private func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }

    // Completes one synthetic HTTP response unless the task was cancelled.
    private func send(
        status: Int,
        body: Data,
        contentType: String = "application/octet-stream"
    ) {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped else { return }
        guard let url = request.url else { return }
        let headers = ["Content-Type": contentType]
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// Verifies that one GitLFS instance can run concurrent and sequential
// downloads on a shared URLSession, and that upload cancellation does
// not tear down in-flight image downloads.
@Suite("GitLFS Shared Session Tests", .serialized)
struct GitLFSSharedSessionTests {
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // Builds a client whose URL loading stack is intercepted by this suite's stub.
    private func makeClient() -> GitLFS {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SharedSessionLFSURLProtocol.self]
        return GitLFS(
            serverURL: "https://\(SharedSessionLFSURLProtocol.host)/lfs",
            sessionConfiguration: config
        )
    }

    // Stores one unique payload per index so concurrent downloads cannot
    // accidentally pass by returning each other's bytes.
    private func makeFixtures(count: Int) -> [(oid: String, data: Data)] {
        (0..<count).map { index in
            let payload = Data(repeating: UInt8(index), count: 128 + index)
            return (oid: sha256Hex(payload), data: payload)
        }
    }

    // Confirms one GitLFS instance can fetch many objects at once, which
    // is the timeline image-load pattern that crashed on per-request sessions.
    @Test func concurrentDownloadsOnSharedClientRoundTrip() async throws {
        let fixtures = makeFixtures(count: 12)
        var dataByOID: [String: Data] = [:]
        for fixture in fixtures {
            dataByOID[fixture.oid] = fixture.data
        }
        SharedSessionLFSURLProtocol.reset(dataByOID: dataByOID)
        defer { SharedSessionLFSURLProtocol.reset() }

        let client = makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for fixture in fixtures {
                group.addTask {
                    let downloaded = try await client.downloadData(
                        oid: fixture.oid,
                        size: Int64(fixture.data.count)
                    )
                    #expect(downloaded == fixture.data)
                }
            }
            try await group.waitForAll()
        }
    }

    // Confirms cancelActiveUpload must not invalidate the shared session
    // or cancel downloads that happen to be in flight.
    @Test func cancelActiveUploadLeavesDownloadsRunning() async throws {
        let fixtures = makeFixtures(count: 8)
        var dataByOID: [String: Data] = [:]
        for fixture in fixtures {
            dataByOID[fixture.oid] = fixture.data
        }
        SharedSessionLFSURLProtocol.reset(dataByOID: dataByOID, downloadDelay: 0.2)
        defer { SharedSessionLFSURLProtocol.reset() }

        let client = makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for fixture in fixtures {
                group.addTask {
                    let downloaded = try await client.downloadData(
                        oid: fixture.oid,
                        size: Int64(fixture.data.count)
                    )
                    #expect(downloaded == fixture.data)
                }
            }

            try await Task.sleep(for: .milliseconds(50))
            client.cancelActiveUpload()
            try await group.waitForAll()
        }
    }

    // Confirms a single client can issue sequential downloads without
    // invalidating the session between requests.
    @Test func sequentialDownloadsReuseSession() async throws {
        let fixtures = makeFixtures(count: 3)
        var dataByOID: [String: Data] = [:]
        for fixture in fixtures {
            dataByOID[fixture.oid] = fixture.data
        }
        SharedSessionLFSURLProtocol.reset(dataByOID: dataByOID)
        defer { SharedSessionLFSURLProtocol.reset() }

        let client = makeClient()
        for fixture in fixtures {
            let downloaded = try await client.downloadData(
                oid: fixture.oid,
                size: Int64(fixture.data.count)
            )
            #expect(downloaded == fixture.data)
        }
    }
}
