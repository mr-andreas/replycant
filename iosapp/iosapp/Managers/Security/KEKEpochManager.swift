import Foundation
import CryptoKit
import LibGit2

// Manages KEK epoch files so devices can rotate and redistribute encryption access without re-encrypting all objects.
final class KEKEpochManager {
    private let repository: Repository
    private let ageIdentityLoader: () throws -> Curve25519.KeyAgreement.PrivateKey
    private var kekCache: [Int: Data] = [:]

    // Allows recovery flows to decrypt epochs with an injected key without mutating the app's primary keychain identity.
    init(
        repository: Repository,
        ageIdentityLoader: @escaping () throws -> Curve25519.KeyAgreement.PrivateKey = {
            try ClientIdentityManager.shared.agePrivateKey()
        }
    ) {
        self.repository = repository
        self.ageIdentityLoader = ageIdentityLoader
    }

    // Returns the active epoch number so callers can tag newly encrypted manifests and pointers correctly.
    func currentEpoch() throws -> Int? {
        guard repository.fileExists(at: "encryption/current") else {
            return nil
        }
        let currentText = try repository.readFile(at: "encryption/current").trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(currentText)
    }

    // Loads and caches the KEK for a specific epoch to avoid repeated age decryption during sync loops.
    func loadKEK(epoch: Int) throws -> Data {
        if let cached = kekCache[epoch] {
            return cached
        }
        let path = "encryption/epochs/\(epoch).age"
        let encryptedText = try repository.readFile(at: path)
        let encryptedData = Data(encryptedText.utf8)
        let identity = try ageIdentityLoader()
        let kek = try AgeCrypto.decrypt(ciphertext: encryptedData, identity: identity)
        kekCache[epoch] = kek
        return kek
    }

    // Resolves the active KEK and epoch in one call so encryption sites can use consistent metadata.
    func loadCurrentKEK() throws -> (epoch: Int, kek: Data) {
        guard let epoch = try currentEpoch() else {
            throw IdentityError.noAgeIdentity
        }
        return (epoch, try loadKEK(epoch: epoch))
    }

    // Builds first-epoch repository files so bootstrap can atomically commit pubkeys and encryption state together.
    func bootstrapFilesForFirstEpoch(recipientAgePubkeys: [String]) throws -> [(path: String, content: String)] {
        let recipients = try parseRecipients(agePubkeys: recipientAgePubkeys)
        let kek = EncryptionUtils.randomKey(length: 32)
        let encryptedEpoch = try AgeCrypto.encrypt(plaintext: kek, recipients: recipients)
        guard let encryptedText = String(data: encryptedEpoch, encoding: .utf8) else {
            throw IdentityError.certificateCreationFailed
        }
        kekCache[1] = kek
        return [
            (path: "gitdb/version", content: "1\n"),
            (path: "encryption/current", content: "1\n"),
            (path: "encryption/epochs/1.age", content: encryptedText)
        ]
    }

    // Re-wraps all existing epochs for a new recipient set so newly linked devices can decrypt historical KEKs.
    func rewrappedEpochFilesIncludingRecipients(_ recipientAgePubkeys: [String]) throws -> [(path: String, content: String)] {
        let recipients = try parseRecipients(agePubkeys: recipientAgePubkeys)
        let epochPaths = try repository.listFiles(in: "encryption/epochs").filter { $0.hasSuffix(".age") }.sorted()
        var files: [(path: String, content: String)] = []
        for epochPath in epochPaths {
            let epochName = (epochPath as NSString).lastPathComponent.replacingOccurrences(of: ".age", with: "")
            guard let epoch = Int(epochName) else {
                continue
            }
            let kek = try loadKEK(epoch: epoch)
            let encryptedEpoch = try AgeCrypto.encrypt(plaintext: kek, recipients: recipients)
            guard let encryptedText = String(data: encryptedEpoch, encoding: .utf8) else {
                throw IdentityError.certificateCreationFailed
            }
            files.append((path: "encryption/epochs/\(epoch).age", content: encryptedText))
        }
        return files
    }

    // Parses Bech32 age public keys from repository/QR payloads into CryptoKit recipient keys for encryption.
    private func parseRecipients(agePubkeys: [String]) throws -> [Curve25519.KeyAgreement.PublicKey] {
        try agePubkeys.map { key in
            let decoded = try Bech32.decode(key)
            guard decoded.hrp == "age" else {
                throw IdentityError.noAgeIdentity
            }
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: decoded.data)
        }
    }
}
