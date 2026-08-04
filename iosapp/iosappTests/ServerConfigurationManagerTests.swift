import Foundation
import CryptoKit
import Testing
@testable import iosapp

// Ensures server URL persistence can be updated independently, which supports repointing origin from Settings.
@MainActor
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
    }
}

