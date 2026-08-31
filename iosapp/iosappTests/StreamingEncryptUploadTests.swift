import Foundation
import Testing
import CryptoKit
import LibGit2
@testable import iosapp

// Captures streamed LFS uploads so encrypting transport tests can assert exact ciphertext bytes without a real server.
final class StreamingUploadURLProtocol: URLProtocol {
    private static var uploadedDataByOID: [String: Data] = [:]
    private static let lock = NSLock()

    // Resets captured upload payloads between tests to keep assertions isolated.
    static func reset() {
        lock.lock()
        uploadedDataByOID = [:]
        lock.unlock()
    }

    // Returns one uploaded payload by OID for ciphertext equivalence assertions.
    static func uploadedData(for oid: String) -> Data? {
        lock.lock()
        let value = uploadedDataByOID[oid]
        lock.unlock()
        return value
    }

    // Intercepts requests for the synthetic test LFS host.
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stream-lfs.local"
    }

    // Reuses the same request object because request rewriting is unnecessary for this stub transport.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // Handles batch and upload endpoints by returning deterministic LFS JSON and storing streamed PUT bodies.
    override func startLoading() {
        guard let url = request.url else {
            send(status: 400, body: Data())
            return
        }

        if url.path.hasSuffix("/objects/batch"), request.httpMethod == "POST" {
            handleBatchRequest()
            return
        }

        if url.path.hasPrefix("/lfs/upload/"), request.httpMethod == "PUT" {
            let oid = String(url.path.dropFirst("/lfs/upload/".count))
            let body = request.httpBody ?? readBody(from: request.httpBodyStream) ?? Data()
            Self.lock.lock()
            Self.uploadedDataByOID[oid] = body
            Self.lock.unlock()
            send(status: 200, body: Data())
            return
        }

        send(status: 404, body: Data())
    }

    // Releases no resources because request handling is synchronous in this stub.
    override func stopLoading() {}

    // Emits one upload action for each requested object so GitLFS can perform the subsequent PUT.
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

        let response: [String: Any] = [
            "objects": [[
                "oid": oid,
                "size": size.int64Value,
                "actions": [
                    "upload": [
                        "href": "https://stream-lfs.local/lfs/upload/\(oid)",
                        "header": [:]
                    ]
                ]
            ]]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        send(status: 200, body: data, contentType: "application/vnd.git-lfs+json")
    }

    // Reads streamed request bodies so upload assertions work for URLSession streamed requests.
    private func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
            } else {
                break
            }
        }
        return output.isEmpty ? nil : output
    }

    // Returns one synthetic HTTP response for intercepted requests.
    private func send(status: Int, body: Data, contentType: String = "application/octet-stream") {
        guard let url = request.url else { return }
        let headers = ["Content-Type": contentType]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// Verifies streaming hash and upload encryption produce deterministic ciphertext equivalent to the existing in-memory algorithm.
@Suite("Streaming Encrypt Upload Tests", .serialized)
struct StreamingEncryptUploadTests {
    // Creates one deterministic payload large enough to span multiple encryption chunks.
    private func makeFixtureData(size: Int) -> Data {
        Data((0..<size).map { UInt8($0 % 251) })
    }

    // Converts SHA256 digest bytes into lowercase hex to match LFSPointer OID formatting.
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Confirms streaming hash computation matches legacy in-memory encryption outputs exactly.
    @Test("computeStreamingHashes matches in-memory encryption outputs")
    func computeStreamingHashesMatchesInMemoryEncryption() throws {
        let plaintext = makeFixtureData(size: 2_500_000)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-hash-fixture-\(UUID().uuidString).bin")
        try plaintext.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let dek = EncryptionUtils.randomKey(length: 32)
        let hashes = try EncryptionUtils.computeStreamingHashes(
            fileURL: fileURL,
            dek: dek
        )
        let encrypted = try EncryptionUtils.encryptChunkedBinary(
            plaintext: plaintext,
            dek: dek
        )

        #expect(hashes.plaintextSHA256 == sha256Hex(plaintext))
        #expect(hashes.encryptedOID == sha256Hex(encrypted))
        #expect(hashes.encryptedSize == Int64(encrypted.count))
        #expect(hashes.plaintextSize == Int64(plaintext.count))
    }

    // Confirms uploadEncrypted streams exactly the same ciphertext bytes as encryptChunkedBinary would produce.
    @Test("uploadEncrypted streams deterministic ciphertext bytes")
    func uploadEncryptedStreamsExpectedCiphertext() async throws {
        StreamingUploadURLProtocol.reset()

        let plaintext = makeFixtureData(size: 2_200_000)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-upload-fixture-\(UUID().uuidString).bin")
        try plaintext.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let dek = EncryptionUtils.randomKey(length: 32)
        let hashes = try EncryptionUtils.computeStreamingHashes(
            fileURL: fileURL,
            dek: dek
        )

        let expectedCiphertext = try EncryptionUtils.encryptChunkedBinary(
            plaintext: plaintext,
            dek: dek
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StreamingUploadURLProtocol.self] + (sessionConfiguration.protocolClasses ?? [])
        let lfsClient = GitLFS(serverURL: "https://stream-lfs.local/lfs", sessionConfiguration: sessionConfiguration)
        let pointer = try await EncryptedLFS.uploadEncrypted(
            fileURL: fileURL,
            dek: dek,
            oid: hashes.encryptedOID,
            size: hashes.encryptedSize,
            lfsClient: lfsClient
        )

        #expect(pointer.oid == hashes.encryptedOID)
        #expect(pointer.size == hashes.encryptedSize)

        let captured = try #require(StreamingUploadURLProtocol.uploadedData(for: hashes.encryptedOID))
        #expect(captured == expectedCiphertext)
    }
}
