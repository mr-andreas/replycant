import Foundation
import Testing
import CryptoKit
import LibGit2
@testable import iosapp

// Stubs Git LFS HTTP batch/download responses so Repository.loadLFSData can run without a real server.
final class MockLFSURLProtocol: URLProtocol {
    static var dataByOID: [String: Data] = [:]

    // Intercepts requests targeting the deterministic in-test LFS host.
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "test-lfs.local"
    }

    // Prevents request loops by reusing the same request object.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // Handles one intercepted request with in-memory JSON/data responses.
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

    // Finishes request handling; no long-lived resources exist in this protocol.
    override func stopLoading() {}

    // Produces one Git LFS batch-download response containing a direct download action URL.
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

    // Reads streamed HTTP bodies so batch request parsing works across URLSession request representations.
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

    // Sends one synthetic HTTP response back to URL loading system.
    private func send(status: Int, body: Data, contentType: String = "application/octet-stream") {
        guard let url = request.url else { return }
        let headers = ["Content-Type": contentType]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// Verifies encrypted LFS pointer metadata in fixtures can be decrypted through Repository.loadLFSData.
@Suite("Repository Encrypted LFS Load Tests", .serialized)
struct RepositoryEncryptedLFSLoadTests {
    // Creates isolated test repository paths so encryption fixtures do not affect other tests.
    private func makeRepositoryPath() -> String {
        let tempDir = NSTemporaryDirectory()
        return (tempDir as NSString).appendingPathComponent("encrypted-lfs-test-\(UUID().uuidString)")
    }

    // Computes deterministic SHA256 strings used by LFSPointer and mock LFS object lookup.
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Ensures encrypted pointers with x-replycant metadata decrypt correctly via loadLFSData.
    @Test func testLoadLFSDataDecryptsEncryptedPointer() async throws {
        defer {
            MockLFSURLProtocol.dataByOID = [:]
        }

        try Git.initialize()
        let repoPath = makeRepositoryPath()
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repository = try Repository.create(at: repoPath, bare: false)
        defer { try? FileManager.default.removeItem(atPath: repoPath) }

        try? ClientIdentityManager.shared.importBundledSimulatorIdentityIfNeeded()
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "iosapp-tests")
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
        let kekEpochManager = KEKEpochManager(repository: repository)
        let bootstrapFiles = try kekEpochManager.bootstrapFilesForFirstEpoch(recipientAgePubkeys: [agePublicKey])
        let kek = try kekEpochManager.loadKEK(epoch: 1)

        let plaintext = Data("fixture-thumbnail-payload".utf8)
        let dek = EncryptionUtils.randomKey(length: 32)
        let encrypted = try EncryptionUtils.encryptChunkedBinary(plaintext: plaintext, dek: dek)
        let wrappedDEK = try EncryptionUtils.wrapDEK(dek, withKEK: kek, kekEpoch: 1).base64EncodedString()
        let encryptedOID = sha256Hex(encrypted)
        MockLFSURLProtocol.dataByOID[encryptedOID] = encrypted

        let pointer = LFSPointer(
            oid: encryptedOID,
            size: Int64(encrypted.count),
            kekEpoch: 1,
            wrappedDEK: wrappedDEK
        ).content

        let pointerPath = "binary/test-device/media.replycant.com/v1alpha1/ThumbnailSet/thumb-1"
        var files = bootstrapFiles
        files.append((path: pointerPath, content: pointer))
        try repository.createCommit(message: "Add encrypted thumbnail pointer", files: files)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockLFSURLProtocol.self] + (sessionConfiguration.protocolClasses ?? [])
        let lfsClient = GitLFS(serverURL: "https://test-lfs.local/lfs", sessionConfiguration: sessionConfiguration)
        let loaded = try await repository.loadLFSData(from: pointerPath, lfsClient: lfsClient)
        #expect(loaded == plaintext)
    }
}
