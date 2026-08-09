import Foundation
import CryptoKit
import Testing
@testable import iosapp

// Ensures server URL persistence can be updated independently, which supports repointing origin from Settings.
@MainActor
@Suite(.serialized)
struct ServerConfigurationManagerTests {

    // Confirms updating server URL also updates the derived LFS endpoint used by media sync clients.
    @Test func testUpdateServerURLPersists() async throws {
        let manager = ServerConfigurationManager.shared

        // Isolate this test from any existing configuration by seeding and then restoring the original value.
        let original = manager.loadURL()
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "gitServerURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "gitServerURL")
            }
        }

        UserDefaults.standard.set("https://example.com/old.git", forKey: "gitServerURL")
        #expect(manager.loadURL() == "https://example.com/old.git")
        #expect(manager.loadLFSURL() == "https://example.com/lfs")

        try manager.updateServerURL("https://example.com/new.git")
        #expect(manager.loadURL() == "https://example.com/new.git")
        #expect(manager.loadLFSURL() == "https://example.com/lfs")
    }

    // Confirms server URL updates publish a change signal so live managers can invalidate stale clients.
    @Test func testUpdateServerURLPostsChangeNotification() async throws {
        let manager = ServerConfigurationManager.shared
        let notificationName = ServerConfigurationManager.lfsURLDidChangeNotification

        // Restore prior Git URL after observing the notification to keep tests isolated.
        let original = manager.loadURL()
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "gitServerURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "gitServerURL")
            }
        }

        var didPost = false
        let observer = NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { _ in
            didPost = true
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        try manager.updateServerURL("https://example.com/notify.git")
        #expect(didPost)
    }

    // Confirms certificate hashes are derived from canonical DER bytes so PEM formatting differences do not affect verification.
    @Test func testCertificateHashUsesCanonicalDERBytes() async throws {
        let compactPem = "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\n-----END CERTIFICATE-----"
        let spacedPem = "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\r\n-----END CERTIFICATE-----\n"

        let expected = SHA256.hash(data: Data("fake-cert".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(ServerConfigurationManager.certificateHash(fromPEM: compactPem) == expected)
        #expect(ServerConfigurationManager.certificateHash(fromPEM: spacedPem) == expected)
    }

    // Confirms LFS endpoint derivation always keeps git origin and rewrites path to /lfs.
    @Test func testDeriveLFSURLFromGitURL() {
        #expect(
            ServerConfigurationManager.deriveLFSURL(from: "https://git.example:8443/repo.git")
            == "https://git.example:8443/lfs"
        )
        #expect(
            ServerConfigurationManager.deriveLFSURL(from: "https://user:pass@git.example/path?x=1")
            == "https://git.example/lfs"
        )
        #expect(
            ServerConfigurationManager.deriveLFSURL(from: "mtls+https://git.example:8443/repo.git")
            == "https://git.example:8443/lfs"
        )
        #expect(
            ServerConfigurationManager.deriveLFSURL(from: "https://git.example:9443/repo.git")
            == "https://git.example:9443/lfs"
        )
    }

    // Confirms every backend service resolves to a gitd route on the git origin.
    // Media services are no longer exposed on their own ports, so deriving them
    // any other way would bypass gitd's mTLS boundary and fail to connect.
    @Test func testDeriveServiceURLKeepsGitOrigin() {
        #expect(
            ServerConfigurationManager.deriveServiceURL(from: "https://git.example:8443/repo.git", path: "/decryptd")
            == "https://git.example:8443/decryptd"
        )
        #expect(
            ServerConfigurationManager.deriveServiceURL(from: "mtls+https://git.example:8443/repo.git", path: "/transcoded")
            == "https://git.example:8443/transcoded"
        )
        #expect(
            ServerConfigurationManager.deriveServiceURL(from: "https://user:pass@git.example/path?x=1", path: "/decryptd")
            == "https://git.example/decryptd"
        )
        #expect(ServerConfigurationManager.deriveServiceURL(from: "not a url", path: "/decryptd") == nil)
        #expect(
            ServerConfigurationManager.deriveServiceURL(from: "https://git.example:9443/repo.git", path: "/decryptd")
            == "https://git.example:9443/decryptd"
        )
    }

    // Confirms simulator auto-connect honors a local git-url override so
    // debug launches follow a remapped gitd port instead of always using 8443.
    @Test func testResolveSimulatorGitURLPrefersBundledOverride() {
        #expect(
            ServerConfigurationManager.resolveSimulatorGitURL(bundledGitURL: nil)
            == "https://replycant.local:8443"
        )
        #expect(
            ServerConfigurationManager.resolveSimulatorGitURL(bundledGitURL: "   ")
            == "https://replycant.local:8443"
        )
        #expect(
            ServerConfigurationManager.resolveSimulatorGitURL(
                bundledGitURL: "https://replycant.local:9443\n"
            )
            == "https://replycant.local:9443"
        )
    }

    // Confirms user-entered discovery addresses consistently normalize to config.json endpoints.
    @Test func testDiscoveryConfigURLNormalization() {
        #expect(
            ServerConfigurationManager.discoveryConfigURL(from: "http://localhost:8080")?.absoluteString
            == "http://localhost:8080/config.json"
        )
        #expect(
            ServerConfigurationManager.discoveryConfigURL(from: "http://localhost:8080/")?.absoluteString
            == "http://localhost:8080/config.json"
        )
        #expect(
            ServerConfigurationManager.discoveryConfigURL(from: "http://localhost:8080/config.json")?.absoluteString
            == "http://localhost:8080/config.json"
        )
        #expect(
            ServerConfigurationManager.discoveryConfigURL(from: "http://localhost:8080/bootstrap")?.absoluteString
            == "http://localhost:8080/bootstrap/config.json"
        )
        #expect(ServerConfigurationManager.discoveryConfigURL(from: "not-a-url") == nil)
    }

    // Confirms recovery discovery rejects mismatched CA fingerprints before saving configuration.
    @Test func testDiscoverAndConfigureRejectsMismatchedCAHash() async throws {
        let manager = ServerConfigurationManager.shared
        manager.clearConfiguration()

        let certPEM = "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\n-----END CERTIFICATE-----"
        URLProtocolStub.responseData = try JSONSerialization.data(withJSONObject: [
            "url": "https://replycant.local:8443",
            "ca": certPEM,
        ])
        URLProtocolStub.statusCode = 200

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: sessionConfig)

        await #expect(throws: ConfigurationError.self) {
            _ = try await manager.discoverAndConfigure(
                discoveryURLString: "http://localhost:8080",
                expectedCAHash: String(repeating: "b", count: 64),
                session: session
            )
        }
        #expect(manager.loadConfiguration() == nil)
    }

    // Confirms successful discovery with matching hash persists both URL and CA for later mTLS setup.
    @Test func testDiscoverAndConfigurePersistsWhenHashMatches() async throws {
        let manager = ServerConfigurationManager.shared
        manager.clearConfiguration()
        defer { manager.clearConfiguration() }

        let certPEM = "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\n-----END CERTIFICATE-----"
        URLProtocolStub.responseData = try JSONSerialization.data(withJSONObject: [
            "url": "https://replycant.local:8443",
            "ca": certPEM,
        ])
        URLProtocolStub.statusCode = 200

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: sessionConfig)

        let expected = ServerConfigurationManager.certificateHash(fromPEM: certPEM)!
        let config = try await manager.discoverAndConfigure(
            discoveryURLString: "http://localhost:8080",
            expectedCAHash: expected,
            session: session
        )

        #expect(config.url == "https://replycant.local:8443")
        #expect(manager.loadURL() == "https://replycant.local:8443")
        #expect(manager.loadCACertificate() == certPEM)
    }
}

// Replaces network transport so discovery tests can deterministically return synthetic payloads.
private final class URLProtocolStub: URLProtocol {
    static var responseData = Data()
    static var statusCode = 200

    // Declares all requests as stubbed to keep discovery tests independent from network state.
    override class func canInit(with request: URLRequest) -> Bool {
        _ = request
        return true
    }

    // Returns requests unchanged because the test suite doesn't need URL canonicalization behavior.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // Delivers configured response bytes so tests can validate CA-hash checks without a live server.
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://localhost")!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    // Exists to satisfy URLProtocol and indicates this stub performs no asynchronous cleanup.
    override func stopLoading() {}
}

