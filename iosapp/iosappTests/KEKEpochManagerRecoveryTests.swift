import CryptoKit
import Foundation
import LibGit2
import Testing
@testable import iosapp

// Verifies KEK epoch decryption can run against injected recovery identities without touching keychain state.
struct KEKEpochManagerRecoveryTests {
    // Confirms an injected identity can decrypt epoch files even when no matching key exists in Keychain.
    @Test func loadCurrentKEKUsesInjectedIdentity() throws {
        let tempRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("kek-inject-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)

        let repo = try Repository.create(at: tempRoot, bare: false)
        let injectedIdentity = Curve25519.KeyAgreement.PrivateKey()
        let plaintextKEK = Data(repeating: 0x7A, count: 32)
        let encryptedEpoch = try AgeCrypto.encrypt(
            plaintext: plaintextKEK,
            recipients: [injectedIdentity.publicKey]
        )
        let epochText = try #require(String(data: encryptedEpoch, encoding: .utf8))

        try repo.createCommit(
            message: "seed encrypted epoch",
            files: [
                (path: "encryption/current", content: "1\n"),
                (path: "encryption/epochs/1.age", content: epochText),
            ]
        )

        let manager = KEKEpochManager(repository: repo, ageIdentityLoader: { injectedIdentity })
        let current = try manager.loadCurrentKEK()
        #expect(current.epoch == 1)
        #expect(current.kek == plaintextKEK)
    }

    // Confirms the injected key must match recipients and cannot decrypt foreign epoch envelopes.
    @Test func loadCurrentKEKRejectsMismatchedInjectedIdentity() throws {
        let tempRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("kek-inject-mismatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)

        let repo = try Repository.create(at: tempRoot, bare: false)
        let authorizedIdentity = Curve25519.KeyAgreement.PrivateKey()
        let unauthorizedIdentity = Curve25519.KeyAgreement.PrivateKey()
        let plaintextKEK = Data(repeating: 0x41, count: 32)
        let encryptedEpoch = try AgeCrypto.encrypt(
            plaintext: plaintextKEK,
            recipients: [authorizedIdentity.publicKey]
        )
        let epochText = try #require(String(data: encryptedEpoch, encoding: .utf8))

        try repo.createCommit(
            message: "seed encrypted epoch",
            files: [
                (path: "encryption/current", content: "1\n"),
                (path: "encryption/epochs/1.age", content: epochText),
            ]
        )

        let manager = KEKEpochManager(repository: repo, ageIdentityLoader: { unauthorizedIdentity })
        #expect(throws: (any Error).self) {
            _ = try manager.loadCurrentKEK()
        }
    }
}
