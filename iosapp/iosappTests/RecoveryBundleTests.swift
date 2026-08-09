import Foundation
import Testing
@testable import iosapp

// Protects the recovery bundle contract so key-export compatibility cannot drift silently.
struct RecoveryBundleTests {
    private static let samplePEM = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEID4fXxFf2A62NV6yIh5fBO7F9RheR8fIuYzDX7r1iWzqoAoGCCqGSM49
    AwEHoUQDQgAE4QxF9i7bE7Emo5zwHWQ/PF2hVGRjQ0gFzQkk+zROf4xIhT4uHnq+
    qz6mJfXwAhgB+Fkg4anSg93vB7DbeGkBMQ==
    -----END EC PRIVATE KEY-----
    """

    private static let sampleAgeSecret = "AGE-SECRET-KEY-1QG8G4Y8R8PFQ7FSPAVM6Y8W2FM9R8R0VHW8Q7M67QZTL0YEAX5G5Q4JQ2T"

    private static let samplePlaintext = RecoveryBundle.Plaintext(
        version: 1,
        label: "Home safe",
        uuid: "f2b0ef64-4d31-4bea-902f-5f1117de844c",
        created: "2026-08-09T19:00:00Z",
        discoveryURL: "http://replycant.local:8080",
        caSHA256: String(repeating: "a", count: 64),
        p256PrivateKeyPEM: samplePEM,
        agePrivateKey: sampleAgeSecret
    )

    // Verifies bundle encryption/decryption preserves all fields under a correct password.
    @Test func roundTripEnvelope() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        let decrypted = try RecoveryBundle.decrypt(
            envelope: envelope,
            password: "correct horse battery staple"
        )
        #expect(decrypted == Self.samplePlaintext)
    }

    // Verifies wrong passwords fail closed so weak UX cannot silently accept the wrong secret.
    @Test func wrongPasswordIsRejected() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        #expect(throws: (any Error).self) {
            _ = try RecoveryBundle.decrypt(envelope: envelope, password: "wrong password")
        }
    }

    // Verifies ciphertext tampering is detected by AES-GCM authentication tags.
    @Test func tamperedCiphertextIsRejected() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        var bytes = try RecoveryBundle.decodeBase64(envelope.ciphertext)
        bytes[bytes.count - 1] ^= 0x01
        let tampered = RecoveryBundle.Envelope(
            v: envelope.v,
            kdf: envelope.kdf,
            cipher: envelope.cipher,
            nonce: envelope.nonce,
            ciphertext: RecoveryBundle.encodeBase64(bytes)
        )

        #expect(throws: (any Error).self) {
            _ = try RecoveryBundle.decrypt(envelope: tampered, password: "correct horse battery staple")
        }
    }

    // Verifies unknown envelope versions are rejected instead of being interpreted ambiguously.
    @Test func unknownVersionIsRejected() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        let unknown = RecoveryBundle.Envelope(
            v: envelope.v + 1,
            kdf: envelope.kdf,
            cipher: envelope.cipher,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        #expect(throws: RecoveryBundle.Error.self) {
            _ = try RecoveryBundle.decrypt(envelope: unknown, password: "correct horse battery staple")
        }
    }

    // Verifies all supported input forms parse to the same envelope payload.
    @Test func parseAcceptsJSONURLAndBareBase64() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        let json = try RecoveryBundle.envelopeJSONString(envelope)
        let fromJSON = try RecoveryBundle.parseEnvelope(from: json)
        #expect(fromJSON == envelope)

        let deepLink = try RecoveryBundle.deepLinkString(for: envelope)
        let fromURL = try RecoveryBundle.parseEnvelope(from: deepLink)
        #expect(fromURL == envelope)

        let bareBase64 = try RecoveryBundle.base64EnvelopeString(envelope)
        let fromBare = try RecoveryBundle.parseEnvelope(from: bareBase64)
        #expect(fromBare == envelope)
    }

    // Verifies envelope JSON stays within QR level-H capacity so long-term paper backups remain scannable.
    @Test func envelopeStaysUnderLevelHCapacity() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        let json = try RecoveryBundle.envelopeJSONString(envelope)
        #expect(json.utf8.count < 1273)
    }

    // Pins a committed cross-language vector so Swift and Go decryption stay wire-compatible.
    @Test func decryptsCommittedGoldenFixture() throws {
        let fixture = try loadGoldenFixture()
        let decrypted = try RecoveryBundle.decrypt(envelope: fixture.envelope, password: fixture.password)
        #expect(decrypted == fixture.plaintext)
    }

    // Loads the shared repository fixture so Swift tests validate the exact vector consumed by Go tests.
    private func loadGoldenFixture() throws -> GoldenFixture {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = repositoryRoot.appendingPathComponent("testdata/recovery/recovery_bundle_golden.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(GoldenFixture.self, from: data)
    }
}

// Represents the shared golden fixture payload that both Swift and Go tests must decrypt identically.
private struct GoldenFixture: Decodable {
    let password: String
    let envelope: RecoveryBundle.Envelope
    let plaintext: RecoveryBundle.Plaintext
}
