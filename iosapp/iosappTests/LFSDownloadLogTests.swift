import Foundation
import CryptoKit
import Testing
import LibGit2

// Provides an LFS mock isolated to this suite so parallel suites cannot
// overwrite its in-memory object map.
final class LogTestLFSURLProtocol: URLProtocol {
    static var dataByOID: [String: Data] = [:]

    // Restricts interception to deterministic in-test LFS hosts.
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "test-lfs.local"
    }

    // Reuses the same request instance to avoid protocol loop churn.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // Serves one request using in-memory batch and download responses.
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
            if let data = Self.dataByOID[oid] {
                send(status: 200, body: data)
            } else {
                send(status: 404, body: Data())
            }
            return
        }

        send(status: 404, body: Data())
    }

    // No retained resources exist after request completion.
    override func stopLoading() {}

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

        let responseObject: [String: Any]
        if Self.dataByOID[oid] != nil {
            responseObject = [
                "oid": oid,
                "size": size.int64Value,
                "actions": [
                    "download": [
                        "href": "https://test-lfs.local/lfs/download/\(oid)",
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

    // Completes one synthetic HTTP response for URL loading clients.
    private func send(
        status: Int,
        body: Data,
        contentType: String = "application/octet-stream"
    ) {
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

// Verifies that LFS object downloads produce exactly one compact
// summary log line per object and that the old multi-line chatter is
// gone. The summary line must include oid, HTTP status, byte count,
// TTFB, and total elapsed time so operators can diagnose transfer
// performance from logs alone.
@Suite("LFS Download Log Tests", .serialized)
struct LFSDownloadLogTests {
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // Redirects stdout to a pipe for the duration of `work` so tests
    // can assert on exact print() output without modifying production
    // code.
    private func captureStdout(
        during work: () async throws -> Void
    ) async throws -> String {
        let pipe = Pipe()
        let originalFd = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try await work()
        } catch {
            fflush(stdout)
            dup2(originalFd, STDOUT_FILENO)
            close(originalFd)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }

        fflush(stdout)
        dup2(originalFd, STDOUT_FILENO)
        close(originalFd)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Confirms success-path downloads keep the compact single-line log format.
    @Test func downloadEmitsCompactSummaryLine() async throws {
        let payload = Data(
            "test-download-payload-for-log-shape".utf8
        )
        let oid = sha256Hex(payload)

        LogTestLFSURLProtocol.dataByOID = [oid: payload]
        defer { LogTestLFSURLProtocol.dataByOID = [:] }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LogTestLFSURLProtocol.self]
        let client = GitLFS(
            serverURL: "https://test-lfs.local/lfs",
            sessionConfiguration: config
        )

        let output = try await captureStdout {
            let data = try await client.downloadData(
                oid: oid,
                size: Int64(payload.count)
            )
            #expect(data == payload)
        }

        let lines = output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        // Filter by oid so parallel suites that also print LFS: lines
        // during process-wide stdout capture cannot poison this assertion.
        let lfsLines = lines.filter {
            $0.hasPrefix("LFS:") && $0.contains("oid=\(oid)")
        }
        #expect(
            lfsLines.count == 1,
            Comment(rawValue: "Expected exactly 1 LFS log line for oid,"
                + " got \(lfsLines.count): \(lfsLines)")
        )

        let summary = try #require(lfsLines.first)
        #expect(summary.contains("status=200"))
        #expect(summary.contains("bytes=\(payload.count)"))
        #expect(summary.contains("total="))
        #expect(summary.contains("ms"))

        // Old chatty messages must be gone from this download's lines.
        for line in lfsLines {
            #expect(!line.contains("Batch response status"))
            #expect(!line.contains("Batch request successful"))
            #expect(!line.contains("Downloading from:"))
            #expect(!line.contains("Adding basic authentication"))
            #expect(!line.contains("Sending GET request"))
            #expect(!line.contains("Download response status"))
            #expect(!line.contains("Download successful, received"))
            #expect(!line.contains("Starting download of OID"))
        }
    }

    // Confirms failure paths still emit a diagnosable LFS log line.
    @Test func downloadFailureStillLogs() async throws {
        LogTestLFSURLProtocol.dataByOID = [:]

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LogTestLFSURLProtocol.self]
        let client = GitLFS(
            serverURL: "https://test-lfs.local/lfs",
            sessionConfiguration: config
        )

        let missingOID = sha256Hex(Data("does-not-exist".utf8))

        let output = try await captureStdout {
            do {
                _ = try await client.downloadData(
                    oid: missingOID,
                    size: 100
                )
                Issue.record("Expected download to throw")
            } catch {
                // Expected failure path.
            }
        }

        // Match the missing oid so chatty LFS lines from parallel upload
        // suites (e.g. "Batch response status: 200") cannot be selected.
        let lfsLines = output
            .components(separatedBy: "\n")
            .filter {
                $0.hasPrefix("LFS:")
                    && $0.contains("oid=\(missingOID)")
                    && !$0.isEmpty
            }
        #expect(!lfsLines.isEmpty, "Failure path should still log")

        let failLine = try #require(lfsLines.first)
        #expect(failLine.contains("failed"))
    }
}
