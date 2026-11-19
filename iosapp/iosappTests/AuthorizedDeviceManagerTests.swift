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
    // A real P-256 line so a key set parses. The current device uses
    // the identity manager's own key instead, which is how the row is
    // recognized.
    private let sampleSSH = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHRl+gi7RtSRc6vdZ+Yi9UDbHAjG6AU7bGguZE6PrPipUw+vUZxniQRRaMy/rwuKaIM/KRmDaslS/CpN5+1NvJE= phone"
    private let sampleAge = "age1gffmd3cp4aae4ellqlqladxvtej9za6qsqpyquudjrwj06j4q95qqn5m8a"

    // The list is what Settings shows: recovery keys are not devices,
    // a bootstrap key may have no UUID, and this phone is recognized
    // by its SSH key rather than by the comment stored in the file.
    @Test func listDevicesSplitsNamesAndMarksCurrentDevice() throws {
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "revocation-test")
        let currentUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let otherUUID = "11111111-2222-3333-4444-555555555555"
        let currentName = "zeta-phone-\(currentUUID)"
        let otherName = "iphone-15-pro-\(otherUUID)"
        let issued = try ClientIdentityManager.shared.sshPublicKey(
            comment: "different-comment"
        )
        let current = try keySetFile(name: currentName, ssh: issued, age: sampleAge)
        let other = try keySetFile(name: otherName, ssh: sampleSSH, age: sampleAge)
        let bootstrap = try keySetFile(name: "kitchen-ipad", ssh: sampleSSH, age: sampleAge)
        let recovery = try keySetFile(
            name: "home-safe-22222222-3333-4444-5555-666666666666",
            type: KeySet.typeRecovery,
            ssh: sampleSSH,
            age: sampleAge
        )
        let repo = try commitPubkeys([
            current,
            other,
            bootstrap,
            recovery,
            (path: "pubkeys/notes.yaml", content: "not a key set\n"),
        ])
        defer { try? FileManager.default.removeItem(atPath: repo.workdir ?? "") }

        let devices = try manager.listDevices(repository: repo)
        #expect(devices.map(\.name) == [currentName, otherName, "kitchen-ipad"])
        #expect(devices.map(\.isCurrentDevice) == [true, false, false])
        #expect(devices.map(\.uuid) == [currentUUID, otherUUID, nil])
        #expect(devices.map(\.path) == [current.path, other.path, bootstrap.path])
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
        let currentName = "zeta-phone-\(currentUUID)"
        let otherName = "kitchen-ipad-\(otherUUID)"
        let issued = try ClientIdentityManager.shared.sshPublicKey(comment: "zeta-phone")
        let current = try keySetFile(
            name: currentName,
            ssh: issued,
            age: try agePublic(currentIdentity)
        )
        let other = try keySetFile(
            name: otherName,
            ssh: sampleSSH,
            age: try agePublic(revokedIdentity)
        )
        let recovery = try keySetFile(
            name: "home-safe-22222222-3333-4444-5555-666666666666",
            type: KeySet.typeRecovery,
            ssh: sampleSSH,
            age: try agePublic(recoveryIdentity)
        )
        let repo = try commitPubkeys([
            (path: "gitdb/version", content: "\(DatabaseVersion.current)\n"),
            (path: "encryption/current", content: "1\n"),
            (path: "encryption/epochs/1.age", content: "epoch-one\n"),
            current,
            other,
            recovery,
        ])
        defer { try? FileManager.default.removeItem(atPath: repo.workdir ?? "") }

        let change = try manager.revocationChange(path: other.path, repository: repo)
        #expect(Set(change.deletions) == [other.path])
        #expect(Set(change.files.map(\.path)) == [
            "encryption/current",
            "encryption/epochs/2.age",
            "encryption/recipients.yaml",
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
            try manager.revocationChange(path: current.path, repository: repo)
        }
        #expect(throws: AuthorizedDeviceManager.Error.deviceNotFound) {
            try manager.revocationChange(path: "pubkeys/missing.yaml", repository: repo)
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
        let currentName = "zeta-phone-\(currentUUID)"
        let otherName = "kitchen-ipad-\(otherUUID)"
        let recoveryName = "home-safe-22222222-3333-4444-5555-666666666666"
        let firstKEK = Data(repeating: 0x21, count: 32)
        let firstEpoch = try AgeCrypto.encrypt(
            plaintext: firstKEK,
            recipients: [currentAge.publicKey, revokedIdentity.publicKey, recoveryIdentity.publicKey]
        )
        let firstEpochText = try #require(String(data: firstEpoch, encoding: .utf8))
        let issued = try ClientIdentityManager.shared.sshPublicKey(
            comment: "zeta-phone-\(currentUUID)"
        )
        let current = try keySetFile(
            name: currentName,
            ssh: issued,
            age: try ClientIdentityManager.shared.agePublicKey()
        )
        let other = try keySetFile(
            name: otherName,
            ssh: sampleSSH,
            age: try agePublic(revokedIdentity)
        )
        let recovery = try keySetFile(
            name: recoveryName,
            type: KeySet.typeRecovery,
            ssh: sampleSSH,
            age: try agePublic(recoveryIdentity)
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
                (path: "gitdb/version", content: "\(DatabaseVersion.current)\n"),
                (path: "encryption/current", content: "1\n"),
                (path: "encryption/epochs/1.age", content: firstEpochText),
                current,
                other,
                recovery,
            ]
        )
        try seed.addRemote(name: "origin", url: remotePath)
        try seed.push(remoteName: "origin", branchName: "main")
        let local = try Repository.clone(from: remotePath, to: localPath)
        let seedOID = try #require(local.headOID())

        let registry = ManifestRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        let gitDB = GitDatabase(repository: local, database: database, registry: registry)
        try await manager.revokeDevice(path: other.path, gitDB: gitDB)

        let published = try #require(local.headOID())
        #expect(published != seedOID)
        let publishedCommit = try commitObject(workdir: localPath, oid: published)
        #expect(publishedCommit.parents == [seedOID])
        #expect(publishedCommit.message == "Remove device kitchen-ipad (\(otherUUID))")
        let remote = try Repository(path: remotePath)
        #expect(remote.headOID() == published)

        let verifyPath = (root as NSString).appendingPathComponent("verify")
        let verify = try Repository.clone(from: remotePath, to: verifyPath)
        #expect(!verify.fileExists(at: other.path))
        #expect(verify.fileExists(at: current.path))
        #expect(verify.fileExists(at: recovery.path))
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

    // A migrated library has no sealed name. Sync fills in only this
    // phone's, and leaves a name that is already there untouched.
    @Test func backfillWritesOnlyThisDevicesMissingName() throws {
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "revocation-test")
        let age = try ClientIdentityManager.shared.agePrivateKey()
        let kek = Data(repeating: 0x11, count: 32)
        let epoch = try AgeCrypto.encrypt(plaintext: kek, recipients: [age.publicKey])
        let epochText = try #require(String(data: epoch, encoding: .utf8))
        let ownSSH = try ClientIdentityManager.shared.sshPublicKey()
        let ownName = "zeta-phone-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let otherName = "kitchen-ipad"
        let own = try keySetFile(name: ownName, ssh: ownSSH, age: sampleAge)
        let other = try keySetFile(name: otherName, ssh: sampleSSH, age: sampleAge)
        let repo = try commitPubkeys([
            (path: "encryption/current", content: "1\n"),
            (path: "encryption/epochs/1.age", content: epochText),
            own,
            other,
        ])
        defer { try? FileManager.default.removeItem(atPath: repo.workdir ?? "") }

        let written = try #require(
            try manager.ownDisplayNameBackfill(
                repository: repo,
                displayName: "Andreas's iPhone",
                ownSSHPublicKey: ownSSH
            )
        )
        #expect(written.path == own.path)
        try repo.createCommit(message: "name this device", files: [written])

        let named = try KeySet.parse(try repo.readFile(at: own.path))
        #expect(try named.decryptDisplayName(kek: kek) == "Andreas's iPhone")
        #expect(try KeySet.parse(try repo.readFile(at: other.path)).spec.displayName == nil)
        #expect(
            try manager.ownDisplayNameBackfill(
                repository: repo,
                displayName: "Someone else",
                ownSSHPublicKey: ownSSH
            ) == nil
        )
        let listed = try manager.listDevices(repository: repo)
        #expect(listed.first { $0.path == own.path }?.name == "Andreas's iPhone")
        #expect(listed.first { $0.path == other.path }?.name == otherName)
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

    private func keySetFile(
        name: String,
        type: String = KeySet.typeDevice,
        ssh: String,
        age: String
    ) throws -> (path: String, content: String) {
        let keySet = KeySet(
            apiVersion: KeySet.apiVersionValue,
            kind: KeySet.kindValue,
            metadata: .init(name: name),
            spec: .init(type: type, mtlsPublicKey: ssh, agePublicKey: age)
        )
        return (KeySet.path(name: name), try keySet.yaml())
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

    // Compression's COMPRESSION_ZLIB is raw DEFLATE, so the zlib header
    // and Adler-32 trailer that libgit2 writes have to come off first.
    // Decoding the wrapper as the stream yields garbage, and the commit
    // check then fails as unreadable.
    private func zlibInflate(_ source: Data) throws -> Data {
        guard source.count > 6, source.first == 0x78 else {
            let prefix = source.prefix(8).map { String(format: "%02x", $0) }.joined()
            throw CommitObjectError.unreadable(prefix)
        }
        let payload = source.dropFirst(2).dropLast(4)
        let capacity = max(payload.count * 16, 4096)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let written = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_decode_buffer(
                buffer,
                capacity,
                base,
                payload.count,
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
