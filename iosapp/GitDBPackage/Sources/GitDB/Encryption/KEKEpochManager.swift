import Foundation
import CryptoKit
import LibGit2

// Manages KEK epoch files so devices can rotate and redistribute encryption access without re-encrypting all objects.
public final class KEKEpochManager {
    private let repository: Repository
    private let ageIdentityLoader: () throws -> Curve25519.KeyAgreement.PrivateKey
    // Epoch numbers repeat across key sets, so the cache cannot be
    // keyed by the number alone.
    private var kekCache: [String: Data] = [:]

    // Allows recovery flows to decrypt epochs with an injected key without mutating the app's primary keychain identity.
    public init(
        repository: Repository,
        ageIdentityLoader: @escaping () throws -> Curve25519.KeyAgreement.PrivateKey = {
            try ClientIdentityManager.shared.agePrivateKey()
        }
    ) {
        self.repository = repository
        self.ageIdentityLoader = ageIdentityLoader
    }

    // Returns the active epoch number so callers can tag newly encrypted manifests and pointers correctly.
    public func currentEpoch(root: String = EncryptionLayout.globalRoot) throws -> Int? {
        let path = "\(root)/current"
        guard repository.fileExists(at: path) else {
            return nil
        }
        let currentText = try repository.readFile(at: path).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(currentText)
    }

    // Loads and caches the KEK for one key set so a space epoch is
    // never decrypted with the library key of the same number.
    public func loadKEK(epoch: Int, root: String = EncryptionLayout.globalRoot) throws -> Data {
        let cacheKey = "\(root)\n\(epoch)"
        if let cached = kekCache[cacheKey] {
            return cached
        }
        let path = "\(root)/epochs/\(epoch).age"
        let encryptedText = try repository.readFile(at: path)
        let encryptedData = Data(encryptedText.utf8)
        let identity = try ageIdentityLoader()
        let kek = try AgeCrypto.decrypt(ciphertext: encryptedData, identity: identity)
        kekCache[cacheKey] = kek
        return kek
    }

    // The first epoch's key exists only in memory until bootstrap
    // commits the epoch file. The same manager seals this device's
    // name into that commit, before the file can be decrypted back.
    public func cachedKEK(epoch: Int, root: String = EncryptionLayout.globalRoot) -> Data? {
        kekCache["\(root)\n\(epoch)"]
    }

    // Resolves the active KEK and epoch in one call so encryption sites can use consistent metadata.
    public func loadCurrentKEK(root: String = EncryptionLayout.globalRoot) throws -> (epoch: Int, kek: Data) {
        guard let epoch = try currentEpoch(root: root) else {
            throw IdentityError.noAgeIdentity
        }
        return (epoch, try loadKEK(epoch: epoch, root: root))
    }

    // Builds first-epoch repository files so bootstrap can atomically commit pubkeys and encryption state together.
    // memberName is the first library member. Callers that only need the
    // epoch files, such as fixtures, can omit it.
    public func bootstrapFilesForFirstEpoch(
        recipientAgePubkeys: [String],
        memberName: String? = nil
    ) throws -> [(path: String, content: String)] {
        let recipients = try parseRecipients(agePubkeys: recipientAgePubkeys)
        let kek = EncryptionUtils.randomKey(length: 32)
        let encryptedEpoch = try AgeCrypto.encrypt(plaintext: kek, recipients: recipients)
        guard let encryptedText = String(data: encryptedEpoch, encoding: .utf8) else {
            throw IdentityError.certificateCreationFailed
        }
        kekCache["\(EncryptionLayout.globalRoot)\n1"] = kek
        var files = [
            (path: "gitdb/version", content: "\(DatabaseVersion.current)\n"),
            (path: "encryption/current", content: "1\n"),
            (path: "encryption/epochs/1.age", content: encryptedText),
        ]
        if let memberName {
            let listed = try RecipientList(members: [memberName]).yaml()
            files.append((path: "encryption/recipients.yaml", content: listed))
        }
        return files
    }

    // Starts the next KEK epoch for every key set a library member can
    // read. Older epoch files stay: a removed device already holds those
    // keys from git history.
    public func nextEpochFiles(recipientAgePubkeys: [String]) throws -> [(path: String, content: String)] {
        var files: [(path: String, content: String)] = []
        for root in try keySetRoots() {
            let pubs = try agePubkeys(for: root, base: recipientAgePubkeys)
            files.append(contentsOf: try nextEpochFiles(in: root, recipientAgePubkeys: pubs))
        }
        return files
    }

    // Re-wraps every epoch of every key set so a new library member can
    // read history, including spaces that keep their own key.
    public func rewrappedEpochFilesIncludingRecipients(_ recipientAgePubkeys: [String]) throws -> [(path: String, content: String)] {
        var files: [(path: String, content: String)] = []
        for root in try keySetRoots() {
            let pubs = try agePubkeys(for: root, base: recipientAgePubkeys)
            files.append(contentsOf: try rewrappedEpochFiles(in: root, recipientAgePubkeys: pubs))
        }
        return files
    }

    // Rewrites the library member list. A missing file is filled from
    // the key sets already in the repository, then the name is added
    // or removed.
    public func globalRecipientsFile(adding name: String) throws -> (path: String, content: String) {
        try globalRecipientsFile(changing: name, add: true)
    }

    public func globalRecipientsFile(removing name: String) throws -> (path: String, content: String) {
        try globalRecipientsFile(changing: name, add: false)
    }

    private func globalRecipientsFile(changing name: String, add: Bool) throws -> (path: String, content: String) {
        var members = try RecipientList.read(in: repository, root: EncryptionLayout.globalRoot)?.members
            ?? KeySet.readAll(in: repository).map(\.keySet.metadata.name)
        if add {
            if !members.contains(name) {
                members.append(name)
            }
        } else {
            members.removeAll { $0 == name }
        }
        let content = try RecipientList(members: members).yaml()
        return (path: "\(EncryptionLayout.globalRoot)/recipients.yaml", content: content)
    }

    // The global key set, plus every space that published its own.
    private func keySetRoots() throws -> [String] {
        var roots = [EncryptionLayout.globalRoot]
        let entries = try repository.listFiles(in: EncryptionLayout.spacesPrefix)
        for entry in entries.sorted() {
            let name = (entry as NSString).lastPathComponent
            let current = EncryptionLayout.spaceKeySetRoot(name) + "/current"
            if repository.fileExists(at: current) {
                roots.append(EncryptionLayout.spaceKeySetRoot(name))
            }
        }
        return roots
    }

    // A space key set is wrapped for the library and for anyone listed
    // only on that space. The library list is the caller's base.
    private func agePubkeys(for root: String, base: [String]) throws -> [String] {
        guard root != EncryptionLayout.globalRoot else {
            return base
        }
        guard let extra = try RecipientList.read(in: repository, root: root) else {
            return base
        }
        let known = try KeySet.readAll(in: repository)
        var pubs = base
        for name in extra.members {
            guard let match = known.first(where: { $0.keySet.metadata.name == name }) else {
                throw RecipientListError.invalid
            }
            let pub = match.keySet.spec.agePublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pubs.contains(pub) {
                pubs.append(pub)
            }
        }
        return pubs
    }

    private func nextEpochFiles(in root: String, recipientAgePubkeys: [String]) throws -> [(path: String, content: String)] {
        guard let epoch = try currentEpoch(root: root) else {
            throw IdentityError.noAgeIdentity
        }
        let recipients = try parseRecipients(agePubkeys: recipientAgePubkeys)
        let kek = EncryptionUtils.randomKey(length: 32)
        let encryptedEpoch = try AgeCrypto.encrypt(plaintext: kek, recipients: recipients)
        guard let encryptedText = String(data: encryptedEpoch, encoding: .utf8) else {
            throw IdentityError.certificateCreationFailed
        }
        let next = epoch + 1
        kekCache["\(root)\n\(next)"] = kek
        return [
            (path: "\(root)/current", content: "\(next)\n"),
            (path: "\(root)/epochs/\(next).age", content: encryptedText),
        ]
    }

    private func rewrappedEpochFiles(in root: String, recipientAgePubkeys: [String]) throws -> [(path: String, content: String)] {
        let recipients = try parseRecipients(agePubkeys: recipientAgePubkeys)
        let epochPaths = try repository.listFiles(in: "\(root)/epochs").filter { $0.hasSuffix(".age") }.sorted()
        var files: [(path: String, content: String)] = []
        for epochPath in epochPaths {
            let epochName = (epochPath as NSString).lastPathComponent.replacingOccurrences(of: ".age", with: "")
            guard let epoch = Int(epochName) else {
                continue
            }
            let kek = try loadKEK(epoch: epoch, root: root)
            let encryptedEpoch = try AgeCrypto.encrypt(plaintext: kek, recipients: recipients)
            guard let encryptedText = String(data: encryptedEpoch, encoding: .utf8) else {
                throw IdentityError.certificateCreationFailed
            }
            files.append((path: "\(root)/epochs/\(epoch).age", content: encryptedText))
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
