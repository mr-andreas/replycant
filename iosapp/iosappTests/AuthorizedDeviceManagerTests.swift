import Compression
import CryptoKit
import Foundation
import LibGit2
import Testing
@testable import GitDB
@testable import iosapp

// Verifies the device list and the single commit that removes a device
// and starts a new encryption epoch for whoever remains.
@Suite(.serialized)
struct AuthorizedDeviceManagerTests {
    private let manager = AuthorizedDeviceManager()

    // The list is what Settings shows: recovery keys are not devices,
    // a bootstrap key may have no UUID, and this phone is recognized
    // by its SSH key rather than by the comment stored in the file.
    @Test func listDevicesSplitsNamesAndMarksCurrentDevice() throws {
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "revocation-test")
        let currentUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let otherUUID = "11111111-2222-3333-4444-555555555555"
        let issued = try ClientIdentityManager.shared.sshPublicKey(
            comment: "zeta-phone-\(currentUUID)"
        )
        let tokens = issued.split(separator: " ", maxSplits: 2).map(String.init)
        let storedCurrent = "\(tokens[0]) \(tokens[1]) different-comment\n"

        let currentPub = "pubkeys/zeta-phone-\(currentUUID).pub"
        let otherPub = "pubkeys/iphone-15-pro-\(otherUUID).pub"
        let bootstrapPub = "pubkeys/kitchen-ipad.pub"
        let noAgePub = "pubkeys/no-age.pub"
        let repo = try commitPubkeys([
            (path: currentPub, content: storedCurrent),
            (path: "pubkeys/zeta-phone-\(currentUUID).age", content: "age-current\n"),
            (path: otherPub, content: "ecdsa-sha2-nistp256 AAAAOTHER iphone-15-pro\n"),
            (path: "pubkeys/iphone-15-pro-\(otherUUID).age", content: "age-other\n"),
            (path: bootstrapPub, content: "ecdsa-sha2-nistp256 AAAABOOT kitchen-ipad\n"),
            (path: "pubkeys/kitchen-ipad.age", content: "age-bootstrap\n"),
            (path: noAgePub, content: "ecdsa-sha2-nistp256 AAAANOAGE no-age\n"),
            (
                path: "pubkeys/home-safe-22222222-3333-4444-5555-666666666666.recovery.pub",
                content: "ecdsa-sha2-nistp256 AAAARECOVERY recovery\n"
            ),
            (
                path: "pubkeys/home-safe-22222222-3333-4444-5555-666666666666.recovery.age",
                content: "age-recovery\n"
            ),
        ])
        defer { try? FileManager.default.removeItem(atPath: repo.workdir ?? "") }

        let devices = try manager.listDevices(repository: repo)
        #expect(devices.map(\.name) == [
            "zeta-phone",
            "iphone-15-pro",
            "kitchen-ipad",
            "no-age",
        ])
        #expect(devices.map(\.isCurrentDevice) == [true, false, false, false])
        #expect(devices.map(\.uuid) == [currentUUID, otherUUID, nil, nil])
        #expect(devices.map(\.agePath) == [
            "pubkeys/zeta-phone-\(currentUUID).age",
            "pubkeys/iphone-15-pro-\(otherUUID).age",
            "pubkeys/kitchen-ipad.age",
            nil,
        ])
        #expect(devices.map(\.pubPath) == [currentPub, otherPub, bootstrapPub, noAgePub])
    }

    // One change deletes the other device's keys, wraps the new epoch
    // for the recovery key as well as the devices that stay, and refuses
    // to remove this phone or a key that is already gone.
    @Test func revocationChangeDropsDeviceAndKeepsRecoveryRecipient() throws {
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "revocation-test")
        let currentIdentity = Curve25519.KeyAgreement.PrivateKey()
        let revokedIdentity = Curve25519.KeyAgreement.PrivateKey()
        let recoveryIdentity = Curve25519.KeyAgreement.PrivateKey()
        let currentUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let otherUUID = "11111111-2222-3333-4444-555555555555"
        let currentPub = "pubkeys/zeta-phone-\(currentUUID).pub"
        let otherPub = "pubkeys/kitchen-ipad-\(otherUUID).pub"
        let otherAge = "pubkeys/kitchen-ipad-\(otherUUID).age"
        let issued = try ClientIdentityManager.shared.sshPublicKey(comment: "zeta-phone")
        let repo = try commitPubkeys([
            (path: "gitdb/version", content: "1\n"),
            (path: "encryption/current", content: "1\n"),
            (path: "encryption/epochs/1.age", content: "epoch-one\n"),
            (path: currentPub, content: issued + "\n"),
            (path: "pubkeys/zeta-phone-\(currentUUID).age", content: try agePublic(currentIdentity) + "\n"),
            (path: otherPub, content: "ecdsa-sha2-nistp256 AAAAOTHER kitchen-ipad\n"),
            (path: otherAge, content: try agePublic(revokedIdentity) + "\n"),
            (
                path: "pubkeys/home-safe-22222222-3333-4444-5555-666666666666.recovery.age",
                content: try agePublic(recoveryIdentity) + "\n"
            ),
        ])
        defer { try? FileManager.default.removeItem(atPath: repo.workdir ?? "") }

        let change = try manager.revocationChange(pubPath: otherPub, repository: repo)
        #expect(Set(change.deletions) == [otherPub, otherAge])
        #expect(Set(change.files.map(\.path)) == [
            "encryption/current",
            "encryption/epochs/2.age",
        ])
        #expect(change.files.first { $0.path == "encryption/current" }?.content == "2\n")
        #expect(try repo.readFile(at: "encryption/epochs/1.age") == "epoch-one\n")

        let epochText = try #require(
            change.files.first { $0.path == "encryption/epochs/2.age" }?.content
        )
        let epochData = Data(epochText.utf8)
        let opened = try AgeCrypto.decrypt(ciphertext: epochData, identity: currentIdentity)
        #expect(opened.count == 32)
        #expect(
            try AgeCrypto.decrypt(ciphertext: epochData, identity: recoveryIdentity) == opened
        )
        #expect(throws: (any Error).self) {
            _ = try AgeCrypto.decrypt(ciphertext: epochData, identity: revokedIdentity)
        }

        #expect(throws: AuthorizedDeviceManager.Error.cannotRevokeCurrentDevice) {
            try manager.revocationChange(pubPath: currentPub, repository: repo)
        }
        #expect(throws: AuthorizedDeviceManager.Error.deviceNotFound) {
            try manager.revocationChange(pubPath: "pubkeys/missing.pub", repository: repo)
        }
    }

    // The published commit is the whole feature: the remote gains exactly
    // one commit, and that commit both deletes the key and starts epoch 2.
    @Test func revokeDevicePublishesKeyDeletionAndNewEpoch() async throws {
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "revocation-test")
        let currentAge = try ClientIdentityManager.shared.agePrivateKey()
        let revokedIdentity = Curve25519.KeyAgreement.PrivateKey()
        let recoveryIdentity = Curve25519.KeyAgreement.PrivateKey()
        let currentUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let otherUUID = "11111111-2222-3333-4444-555555555555"
        let currentPub = "pubkeys/zeta-phone-\(currentUUID).pub"
        let otherPub = "pubkeys/kitchen-ipad-\(otherUUID).pub"
        let otherAge = "pubkeys/kitchen-ipad-\(otherUUID).age"
        let recoveryAge = "pubkeys/home-safe-22222222-3333-4444-5555-666666666666.recovery.age"
        let firstKEK = Data(repeating: 0x21, count: 32)
        let firstEpoch = try AgeCrypto.encrypt(
            plaintext: firstKEK,
            recipients: [currentAge.publicKey, revokedIdentity.publicKey, recoveryIdentity.publicKey]
        )
        let firstEpochText = try #require(String(data: firstEpoch, encoding: .utf8))
        let issued = try ClientIdentityManager.shared.sshPublicKey(
            comment: "zeta-phone-\(currentUUID)"
        )

        let root = try makeTempRoot("device-revoke-remote")
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-revoke-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(at: dbURL)
        }
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let seedPath = (root as NSString).appendingPathComponent("seed")
        let localPath = (root as NSString).appendingPathComponent("local")
        try Git.initialize()
        _ = try Repository.create(at: remotePath, bare: true)
        let seed = try Repository.create(at: seedPath, bare: false)
        try seed.createCommit(
            message: "seed",
            files: [
                (path: "gitdb/version", content: "1\n"),
                (path: "encryption/current", content: "1\n"),
                (path: "encryption/epochs/1.age", content: firstEpochText),
                (path: currentPub, content: issued),
                (path: "pubkeys/zeta-phone-\(currentUUID).age", content: try ClientIdentityManager.shared.agePublicKey()),
                (path: otherPub, content: "ecdsa-sha2-nistp256 AAAAOTHER kitchen-ipad"),
                (path: otherAge, content: try agePublic(revokedIdentity)),
                (path: recoveryAge, content: try agePublic(recoveryIdentity)),
            ]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")
        let local = try Repository.clone(from: remotePath, to: localPath)
        let seedOID = try #require(local.headOID())

        let registry = ManifestRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        let gitDB = GitDatabase(repository: local, database: database, registry: registry)
        try await manager.revokeDevice(pubPath: otherPub, gitDB: gitDB)

        let published = try #require(local.headOID())
        #expect(published != seedOID)
        let publishedCommit = try commitObject(workdir: localPath, oid: published)
        #expect(publishedCommit.parents == [seedOID])
        #expect(publishedCommit.message == "Remove device kitchen-ipad (\(otherUUID))")
        let remote = try Repository(path: remotePath)
        #expect(remote.headOID() == published)

        let verifyPath = (root as NSString).appendingPathComponent("verify")
        let verify = try Repository.clone(from: remotePath, to: verifyPath)
        #expect(!verify.fileExists(at: otherPub))
        #expect(!verify.fileExists(at: otherAge))
        #expect(verify.fileExists(at: currentPub))
        #expect(verify.fileExists(at: recoveryAge))
        #expect(try verify.readFile(at: "encryption/epochs/1.age") == firstEpochText)
        #expect(
            try verify.readFile(at: "encryption/current")
                .trimmingCharacters(in: .whitespacesAndNewlines) == "2"
        )
        let epoch2 = Data(try verify.readFile(at: "encryption/epochs/2.age").utf8)
        let opened = try AgeCrypto.decrypt(ciphertext: epoch2, identity: currentAge)
        #expect(opened.count == 32)
        #expect(opened != firstKEK)
        #expect(try AgeCrypto.decrypt(ciphertext: epoch2, identity: recoveryIdentity) == opened)
        #expect(throws: (any Error).self) {
            _ = try AgeCrypto.decrypt(ciphertext: epoch2, identity: revokedIdentity)
        }
    }

    // Commits pubkey fixtures so listing reads them from HEAD the same
    // way the settings screen does.
    private func commitPubkeys(
        _ files: [(path: String, content: String)]
    ) throws -> Repository {
        let root = try makeTempRoot("device-list")
        try Git.initialize()
        let repo = try Repository.create(at: root, bare: false)
        try repo.createCommit(message: "seed pubkeys", files: files)
        return repo
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

    // Reads one loose commit so the test can prove the published history
    // grew by a single commit. The simulator has no git executable.
    private func commitObject(workdir: String, oid: String) throws -> CommitObject {
        let prefix = String(oid.prefix(2))
        let suffix = String(oid.dropFirst(2))
        let path = ((workdir as NSString).appendingPathComponent(".git/objects/\(prefix)") as NSString)
            .appendingPathComponent(suffix)
        let compressed = try Data(contentsOf: URL(fileURLWithPath: path))
        let inflated = try zlibInflate(compressed)
        guard let text = String(data: inflated, encoding: .utf8),
              let headerEnd = text.firstIndex(of: "\u{0}") else {
            throw CommitObjectError.unreadable(compressed.prefix(8).map { String(format: "%02x", $0) }.joined())
        }
        let body = String(text[text.index(after: headerEnd)...])
        let parts = body.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = parts.first.map(String.init) ?? ""
        let parents = header.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("parent ") else { return nil }
            return String(line.dropFirst("parent ".count))
        }
        let message = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return CommitObject(parents: parents, message: message)
    }

    // Inflates a loose git object. NSData's decompressor rejects the
    // zlib wrapper libgit2 writes, so this uses the Compression decoder.
    private func zlibInflate(_ source: Data) throws -> Data {
        let capacity = max(source.count * 16, 4096)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let written = source.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_decode_buffer(
                buffer,
                capacity,
                base,
                source.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard written > 0 else {
            let prefix = source.prefix(8).map { String(format: "%02x", $0) }.joined()
            throw CommitObjectError.unreadable(prefix)
        }
        return Data(bytes: buffer, count: written)
    }
}

// The parent list and message of one commit, which is all the durable
// write test needs to show the removal landed as a single commit.
private struct CommitObject {
    let parents: [String]
    let message: String
}

// Names a commit object the test could not inflate, so a packed or
// truncated object fails as a read error rather than a wrong parent.
private enum CommitObjectError: Error {
    case unreadable(String)
}
