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

    // Verifies wrong passwords fail as a typed error with copy the
    // recovery UI can show instead of a raw CryptoKit failure.
    @Test func wrongPasswordIsRejected() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        #expect(throws: RecoveryBundle.Error.wrongPassword) {
            _ = try RecoveryBundle.decrypt(envelope: envelope, password: "wrong password")
        }
        #expect(
            RecoveryBundle.Error.wrongPassword.errorDescription
                == "The recovery password is incorrect."
        )
    }

    // Verifies ciphertext tampering fails the same way as a wrong
    // password because AES-GCM cannot distinguish the two cases.
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

        #expect(throws: RecoveryBundle.Error.wrongPassword) {
            _ = try RecoveryBundle.decrypt(
                envelope: tampered,
                password: "correct horse battery staple"
            )
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

    // Ensures keep=1 on a recovery deep link is the only input
    // that asks the done step to skip the revoke prompt.
    @Test func requestsKeepingRecoveryKeyFromDeepLinkQuery() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        let deepLink = try RecoveryBundle.deepLinkString(for: envelope)
        let keepTrue = deepLink + "&keep=1"
        let keepWord = deepLink + "&keep=true"
        let keepUpper = deepLink + "&keep=TRUE"
        let keepZero = deepLink + "&keep=0"
        let json = try RecoveryBundle.envelopeJSONString(envelope)
        let bareBase64 = try RecoveryBundle.base64EnvelopeString(envelope)

        #expect(RecoveryBundle.requestsKeepingRecoveryKey(in: keepTrue))
        #expect(RecoveryBundle.requestsKeepingRecoveryKey(in: keepWord))
        #expect(RecoveryBundle.requestsKeepingRecoveryKey(in: keepUpper))
        #expect(!RecoveryBundle.requestsKeepingRecoveryKey(in: deepLink))
        #expect(!RecoveryBundle.requestsKeepingRecoveryKey(in: keepZero))
        #expect(!RecoveryBundle.requestsKeepingRecoveryKey(in: json))
        #expect(!RecoveryBundle.requestsKeepingRecoveryKey(in: bareBase64))
        #expect(
            !RecoveryBundle.requestsKeepingRecoveryKey(
                in: "https://example.com/recover?v=1&d=abc&keep=1"
            )
        )
    }

    // Ensures an embedded pw query unlocks recovery without a
    // prompt, while JSON, bare payload, and foreign schemes stay empty.
    @Test func embeddedPasswordFromDeepLinkQuery() throws {
        let envelope = try RecoveryBundle.encrypt(
            plaintext: Self.samplePlaintext,
            password: "correct horse battery staple"
        )
        let deepLink = try RecoveryBundle.deepLinkString(for: envelope)
        let json = try RecoveryBundle.envelopeJSONString(envelope)
        let bareBase64 = try RecoveryBundle.base64EnvelopeString(envelope)

        #expect(RecoveryBundle.embeddedPassword(in: deepLink + "&pw=secret") == "secret")
        #expect(RecoveryBundle.embeddedPassword(in: deepLink + "&pw=a%20b%26c") == "a b&c")
        #expect(RecoveryBundle.embeddedPassword(in: deepLink + "&pw=") == nil)
        #expect(RecoveryBundle.embeddedPassword(in: deepLink) == nil)
        #expect(RecoveryBundle.embeddedPassword(in: json) == nil)
        #expect(RecoveryBundle.embeddedPassword(in: bareBase64) == nil)
        #expect(
            RecoveryBundle.embeddedPassword(
                in: "https://example.com/recover?v=1&d=abc&pw=secret"
            ) == nil
        )
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
