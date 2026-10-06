import CryptoKit
import Foundation
import Testing
@testable import GitDB
@testable import iosapp

// Covers the wait this device does while the operator authorizes it.
//
// A device on the tailnet path cannot reach anything until this completes: it
// has no CA to trust, no credential, and no route. Every failure mode here is
// therefore indistinguishable from "the server is down" unless it is reported
// precisely, which is what these pin down.
//
// Serialized because URLProtocol registration is per-configuration but the
// stub's scripted response is process-wide, so concurrent cases would answer
// each other's polls.
@Suite(.serialized)
struct TailnetPairingTests {
    private final class BundleMarker {}

    private struct Fixture: Decodable {
        struct WirePayload: Decodable {
            let headscale_url: String
        }

        let secret: String
        let slot: String
        let agePrivateKeyBase64: String
        let payload: WirePayload
        let sealedBase64: String
        let mismatchedCaSealedBase64: String
    }

    private static func fixture() throws -> Fixture {
        let url = try #require(
            Bundle(for: BundleMarker.self).url(forResource: "pairing.fixture", withExtension: "json"),
            "the generated pairing fixture must be bundled with the tests"
        )
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    private static func ageIdentity(_ fixture: Fixture) throws -> Curve25519.KeyAgreement.PrivateKey {
        let raw = try #require(Data(base64Encoded: fixture.agePrivateKeyBase64))
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    // Serves the discovery slot from memory.
    //
    // The real endpoint answers 404 until the operator publishes, so the stub
    // has to be able to do the same: the not-yet-written case is the normal
    // one, not an error path.
    private final class StubDiscovery: URLProtocol, @unchecked Sendable {
        struct Script: Sendable {
            var notFoundResponses: Int
            var body: Data?
            var status: Int
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var script = Script(notFoundResponses: 0, body: nil, status: 200)
        nonisolated(unsafe) private static var requestedHosts: [String] = []

        static func install(_ script: Script) {
            lock.lock()
            Self.script = script
            requestedHosts = []
            lock.unlock()
        }

        // The slot is a subdomain rather than a path, so that is where a test
        // has to look to see which slot was actually polled.
        static var hosts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requestedHosts
        }

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubDiscovery.self]
            return URLSession(configuration: configuration)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.requestedHosts.append(request.url?.host ?? "")
            let pending = Self.script.notFoundResponses
            if pending > 0 {
                Self.script.notFoundResponses = pending - 1
            }
            let script = Self.script
            Self.lock.unlock()

            let status = pending > 0 ? 404 : script.status
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status == 200, let body = script.body {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // The happy path: the operator publishes, the device opens the record with
    // its own age key, and the CA is checked against the fingerprint in the
    // hostname before anything trusts it.
    @Test func returnsTheRecordTheOperatorPublished() async throws {
        let fixture = try Self.fixture()
        StubDiscovery.install(.init(
            notFoundResponses: 0,
            body: try #require(Data(base64Encoded: fixture.sealedBase64)),
            status: 200
        ))

        let payload = try await TailnetPairing.awaitAuthorization(
            secretEncoded: fixture.secret,
            slot: fixture.slot,
            ageIdentity: try Self.ageIdentity(fixture),
            interval: 0,
            timeout: 5,
            session: StubDiscovery.session()
        )

        #expect(payload.headscaleURL == fixture.payload.headscale_url)
        #expect(StubDiscovery.hosts.contains { $0.hasPrefix(fixture.slot) })
    }

    // Authorization is a human action on another device, so the slot is empty
    // for as long as it takes the operator to scan and approve. Giving up on
    // the first 404 would make pairing a race against the user.
    @Test func keepsWaitingWhileTheSlotIsStillEmpty() async throws {
        let fixture = try Self.fixture()
        StubDiscovery.install(.init(
            notFoundResponses: 3,
            body: try #require(Data(base64Encoded: fixture.sealedBase64)),
            status: 200
        ))

        _ = try await TailnetPairing.awaitAuthorization(
            secretEncoded: fixture.secret,
            slot: fixture.slot,
            ageIdentity: try Self.ageIdentity(fixture),
            interval: 0,
            timeout: 5,
            session: StubDiscovery.session()
        )

        #expect(StubDiscovery.hosts.count == 4)
    }

    // A record naming one CA in its hostname and delivering another is the
    // shape a substituted CA takes. It has to be refused here, before the CA
    // is installed, not after the first failed connection.
    @Test func refusesARecordWhoseCAContradictsItsHostname() async throws {
        let fixture = try Self.fixture()
        StubDiscovery.install(.init(
            notFoundResponses: 0,
            body: try #require(Data(base64Encoded: fixture.mismatchedCaSealedBase64)),
            status: 200
        ))

        await #expect(throws: PairingRecord.PairingError.caFingerprintMismatch) {
            try await TailnetPairing.awaitAuthorization(
                secretEncoded: fixture.secret,
                slot: fixture.slot,
                ageIdentity: try Self.ageIdentity(fixture),
                interval: 0,
                timeout: 5,
                session: StubDiscovery.session()
            )
        }
    }

    // Anything other than 200 or 404 means the discovery service is not
    // behaving, which is worth surfacing rather than polling until timeout.
    @Test func reportsAnUnexpectedDiscoveryStatus() async throws {
        let fixture = try Self.fixture()
        StubDiscovery.install(.init(notFoundResponses: 0, body: nil, status: 500))

        await #expect(throws: DiscoveryClient.DiscoveryError.unexpectedStatus(500)) {
            try await TailnetPairing.awaitAuthorization(
                secretEncoded: fixture.secret,
                slot: fixture.slot,
                ageIdentity: try Self.ageIdentity(fixture),
                interval: 0,
                timeout: 5,
                session: StubDiscovery.session()
            )
        }
    }

    // The user is looking at a QR code with no other feedback, so an operator
    // who never scans has to end in a stated timeout rather than a spinner
    // that runs until the app is killed.
    @Test func givesUpWhenTheOperatorNeverAuthorizes() async throws {
        let fixture = try Self.fixture()
        StubDiscovery.install(.init(notFoundResponses: .max, body: nil, status: 200))

        await #expect(throws: DiscoveryClient.DiscoveryError.timedOut) {
            try await TailnetPairing.awaitAuthorization(
                secretEncoded: fixture.secret,
                slot: fixture.slot,
                ageIdentity: try Self.ageIdentity(fixture),
                interval: 0,
                timeout: 0,
                session: StubDiscovery.session()
            )
        }
    }
}

// Covers the QR this device shows the operator.
//
// The two onboarding paths are told apart by which optional field is present,
// so a missing or misnamed one silently sends the operator down the wrong path.
struct PairingQRPayloadTests {
    @Test func carriesTheSecretTheDeviceIsWaitingOn() throws {
        let secret = PairingRecord.createSecret()

        let json = try TailnetPairing.deviceQRPayload(
            publicKeySSH: "ssh-ed25519 AAAA example",
            agePublicKey: "age1example",
            deviceName: "example-device",
            deviceUUID: "00000000-0000-0000-0000-000000000000",
            pairingSecret: secret.encoded
        )

        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        )
        #expect(decoded["pairing_secret"] == secret.encoded)
        #expect(decoded["age_pubkey"] == "age1example")
        #expect(decoded["pubkey"] == "ssh-ed25519 AAAA example")
        #expect(decoded["name"] == "example-device")
        #expect(decoded["uuid"] == "00000000-0000-0000-0000-000000000000")
    }

    // The field name is the contract with the scanning device, and both the
    // webapp writer and QRScanValidation spell it this way.
    @Test func usesTheFieldNameTheScannerLooksFor() throws {
        let json = try TailnetPairing.deviceQRPayload(
            publicKeySSH: "ssh-ed25519 AAAA example",
            agePublicKey: "age1example",
            deviceName: "example-device",
            deviceUUID: "uuid",
            pairingSecret: PairingRecord.createSecret().encoded
        )

        #expect(json.contains("pairing_secret"))
    }
}
