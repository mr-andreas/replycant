import Foundation
import Testing
@testable import iosapp

// Covers the request an already-paired device makes on behalf of a device it
// just scanned.
//
// This endpoint mints a tailnet credential, and the scanned device is waiting
// on a slot it cannot write to itself, so a request that goes to the wrong
// place or omits a field leaves the other device timing out with nothing to
// explain why.
//
// Serialized because the stub's scripted response is process-wide, so
// concurrent cases would answer each other's requests.
@Suite(.serialized)
struct PairingAuthorizationTests {
    // Records what the app sent and replies with a canned response.
    private final class StubServer: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var status = 200
        nonisolated(unsafe) private static var body = Data("sealed".utf8)
        nonisolated(unsafe) private static var seen: URLRequest?

        static func install(status: Int, body: Data = Data("sealed".utf8)) {
            lock.lock()
            Self.status = status
            Self.body = body
            seen = nil
            lock.unlock()
        }

        static var lastRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubServer.self]
            return URLSession(configuration: configuration)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }

        // URLSession strips the body from the request handed to the protocol,
        // so it is captured here where the stream is still readable.
        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            lock.lock()
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                captured.httpBody = Self.drain(stream)
            }
            seen = captured
            lock.unlock()
            return request
        }

        private static func drain(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            return data
        }

        override func startLoading() {
            Self.lock.lock()
            let status = Self.status
            let body = Self.body
            Self.lock.unlock()

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // The field names are gitd's contract, and the path is where gitd serves
    // pairing. A rename on either side would show up only as the other device
    // never being authorized.
    @Test func postsTheSecretAndRecipientToTheServersPairEndpoint() async throws {
        StubServer.install(status: 200)

        _ = try await PairingAuthorization.publish(
            pairingSecret: "AAAA-secret",
            agePublicKey: "age1example",
            serverURL: "https://gitd.example.com:8443",
            session: StubServer.session()
        )

        let request = try #require(StubServer.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://gitd.example.com:8443/pair")

        let rawBody = try #require(request.httpBody)
        let body = try #require(
            try JSONSerialization.jsonObject(with: rawBody) as? [String: String]
        )
        #expect(body["pairing_secret"] == "AAAA-secret")
        #expect(body["age_pubkey"] == "age1example")
    }

    // The stored URL uses the mtls scheme so libgit2 routes through the custom
    // transport. URLSession does not know that scheme, so it has to be undone
    // here rather than failing as an unsupported URL.
    @Test func dialsTheServerOverPlainHTTPS() async throws {
        StubServer.install(status: 200)

        _ = try await PairingAuthorization.publish(
            pairingSecret: "secret",
            agePublicKey: "age1example",
            serverURL: "mtls+https://gitd.example.com:8443",
            session: StubServer.session()
        )

        #expect(StubServer.lastRequest?.url?.absoluteString == "https://gitd.example.com:8443/pair")
    }

    // gitd holds the request open until the record is stored, so a failure
    // here means the other device will never see a record. Surfacing it lets
    // the operator retry instead of both devices waiting on each other.
    @Test func reportsAFailedPublish() async throws {
        StubServer.install(status: 502)

        await #expect(throws: PairingAuthorization.AuthorizationError.publishFailed(502)) {
            try await PairingAuthorization.publish(
                pairingSecret: "secret",
                agePublicKey: "age1example",
                serverURL: "https://gitd.example.com:8443",
                session: StubServer.session()
            )
        }
    }

    // Manual-exposure deployments publish nothing and deliver the record in
    // this response instead, so the bytes have to be handed back rather than
    // discarded.
    @Test func returnsTheSealedRecordTheServerProduced() async throws {
        StubServer.install(status: 200, body: Data([0x01, 0x02, 0x03]))

        let record = try await PairingAuthorization.publish(
            pairingSecret: "secret",
            agePublicKey: "age1example",
            serverURL: "https://gitd.example.com:8443",
            session: StubServer.session()
        )

        #expect(record == Data([0x01, 0x02, 0x03]))
    }

    @Test func refusesAServerURLItCannotBuildARequestFrom() async {
        await #expect(throws: PairingAuthorization.AuthorizationError.invalidServerURL) {
            try await PairingAuthorization.publish(
                pairingSecret: "secret",
                agePublicKey: "age1example",
                serverURL: "   ",
                session: StubServer.session()
            )
        }
    }
}
