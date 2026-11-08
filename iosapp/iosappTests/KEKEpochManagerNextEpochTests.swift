import CryptoKit
import Foundation
import LibGit2
import Testing
@testable import iosapp

// Verifies a revocation can start a new KEK epoch for the devices that
// remain without rewriting epochs a removed device already holds.
struct KEKEpochManagerNextEpochTests {
    // A removed device must be left out of the new epoch, and the epoch
    // it already has must stay byte-for-byte so history is not rewritten.
    @Test func nextEpochAdvancesCurrentAndExcludesDroppedRecipient() throws {
        let root = try makeTempRoot("kek-next")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Git.initialize()
        let repo = try Repository.create(at: root, bare: false)

        let remaining = Curve25519.KeyAgreement.PrivateKey()
        let excluded = Curve25519.KeyAgreement.PrivateKey()
        let firstKEK = Data(repeating: 0x11, count: 32)
        let firstEpoch = try AgeCrypto.encrypt(
            plaintext: firstKEK,
            recipients: [remaining.publicKey, excluded.publicKey]
        )
        let firstEpochText = try #require(String(data: firstEpoch, encoding: .utf8))
        try repo.createCommit(
            message: "seed epoch 1",
            files: [
                (path: "encryption/current", content: "1\n"),
                (path: "encryption/epochs/1.age", content: firstEpochText),
            ]
        )

        let remainingPub = try agePublic(remaining)
        let files = try KEKEpochManager(repository: repo).nextEpochFiles(
            recipientAgePubkeys: [remainingPub]
        )
        #expect(files.map(\.path).sorted() == [
            "encryption/current",
            "encryption/epochs/2.age",
        ])
        #expect(files.first { $0.path == "encryption/current" }?.content == "2\n")

        try repo.createCommit(message: "start epoch 2", files: files)
        #expect(try repo.readFile(at: "encryption/epochs/1.age") == firstEpochText)
        #expect(
            try repo.readFile(at: "encryption/current")
                .trimmingCharacters(in: .whitespacesAndNewlines) == "2"
        )

        let kept = KEKEpochManager(repository: repo, ageIdentityLoader: { remaining })
        let secondKEK = try kept.loadKEK(epoch: 2)
        #expect(secondKEK.count == 32)
        #expect(secondKEK != firstKEK)
        #expect(try kept.loadKEK(epoch: 1) == firstKEK)

        let dropped = KEKEpochManager(repository: repo, ageIdentityLoader: { excluded })
        #expect(throws: (any Error).self) {
            _ = try dropped.loadKEK(epoch: 2)
        }

        // Reading current again is what stops a later revocation from
        // writing over epoch 2 instead of continuing the sequence.
        let third = try KEKEpochManager(repository: repo).nextEpochFiles(
            recipientAgePubkeys: [remainingPub]
        )
        #expect(third.contains { $0.path == "encryption/epochs/3.age" })
        #expect(third.first { $0.path == "encryption/current" }?.content == "3\n")
    }

    // Encryption is mandatory, so a repository with no epoch cannot
    // pretend a removal still produced a new key.
    @Test func nextEpochThrowsWhenRepositoryHasNoEpoch() throws {
        let root = try makeTempRoot("kek-next-missing")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Git.initialize()
        let repo = try Repository.create(at: root, bare: false)
        let recipient = try agePublic(Curve25519.KeyAgreement.PrivateKey())

        #expect(throws: (any Error).self) {
            _ = try KEKEpochManager(repository: repo).nextEpochFiles(
                recipientAgePubkeys: [recipient]
            )
        }
    }

    private func makeTempRoot(_ name: String) throws -> String {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func agePublic(_ key: Curve25519.KeyAgreement.PrivateKey) throws -> String {
        try Bech32.encode(hrp: "age", data: key.publicKey.rawRepresentation)
    }
}
