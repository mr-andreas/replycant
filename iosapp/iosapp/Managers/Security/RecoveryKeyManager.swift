import CryptoKit
import Foundation
import GitDB
import LibGit2
import UIKit

// Coordinates recovery-key creation and revocation so users can regain repository access after key loss.
final class RecoveryKeyManager {
    // Captures shareable outputs generated when a recovery key is created.
    struct CreatedRecoveryKey {
        let label: String
        let uuid: String
        let recoveryPubPath: String
        let recoveryAgePath: String
        let envelopeJSON: String
        let deepLink: String
    }

    // Describes one recovery key detected in pubkeys/ so UI can present actionable state.
    struct RecoveryKeyRecord: Equatable {
        let label: String
        let uuid: String
        let pubPath: String
        let agePath: String
    }

    // Carries the key metadata used in a successful recovery so callers can offer immediate key replacement.
    struct RecoveryResult {
        let usedRecoveryLabel: String
        let usedRecoveryUUID: String
        let discoveredServerURL: String
    }

    // Names creation and revocation failures so settings and onboarding can show specific guidance.
    enum Error: Swift.Error, LocalizedError {
        case missingServerConfiguration
        case invalidServerConfiguration
        case malformedRecoveryFilename
        case noMatchingRecoveryKey
        case alreadyConfiguredDevice
        case missingClientIdentity
        case missingPinnedCA
        case malformedRecoveryAgeKey
        case recoveryKeyNotAuthorized

        // Explains why recovery-key operations failed so users know whether to retry or reconfigure.
        var errorDescription: String? {
            switch self {
            case .missingServerConfiguration:
                return "Server configuration is required before creating a recovery key."
            case .invalidServerConfiguration:
                return "Server configuration is invalid and cannot be used for recovery."
            case .malformedRecoveryFilename:
                return "Recovery key files are malformed."
            case .noMatchingRecoveryKey:
                return "Recovery key not found."
            case .alreadyConfiguredDevice:
                return "Recovery is only available on fresh installs. Reinstall the app and try again."
            case .missingClientIdentity:
                return "Device identity is missing."
            case .missingPinnedCA:
                return "Server trust configuration is missing."
            case .malformedRecoveryAgeKey:
                return "Recovery key age secret is malformed."
            case .recoveryKeyNotAuthorized:
                return "This recovery key is not registered on the server."
            }
        }
    }

    // Rejects recovery on already-configured devices to prevent identity swap confusion and accidental key loss.
    static func shouldRejectRecovery(
        isServerConfigured: Bool,
        repositoryExists: Bool
    ) -> Bool {
        isServerConfigured || repositoryExists
    }

    // Discovery already pinned the CA, so a 401 while presenting the recovery
    // identity means the server no longer lists this key, not a transport fault.
    static func mapRecoveryAuthError(_ error: Swift.Error) -> Swift.Error {
        MTLSTransportError.indicatesHTTPStatus(401, in: error)
            ? Error.recoveryKeyNotAuthorized
            : error
    }

    // Returns true when at least one marked recovery key exists in pubkeys/.
    func hasRecoveryKey(repository: Repository) throws -> Bool {
        try !listRecoveryKeys(repository: repository).isEmpty
    }

    // Lists repository recovery key records by pairing .recovery.pub and .recovery.age entries.
    func listRecoveryKeys(repository: Repository) throws -> [RecoveryKeyRecord] {
        let files = try repository.listFiles(in: "pubkeys")
        let recoveryPubFiles = files
            .filter { $0.hasSuffix(".recovery.pub") }
            .sorted()
        var records: [RecoveryKeyRecord] = []

        for pubPath in recoveryPubFiles {
            guard let (label, uuid) = parseRecoveryKeyName(path: pubPath) else {
                throw Error.malformedRecoveryFilename
            }
            let agePath = "pubkeys/\(label)-\(uuid).recovery.age"
            if files.contains(agePath) {
                records.append(
                    RecoveryKeyRecord(
                        label: label,
                        uuid: uuid,
                        pubPath: pubPath,
                        agePath: agePath
                    )
                )
            }
        }
        return records
    }

    // Creates a new recovery key, publishes marked pubkeys, re-wraps epochs, and returns share payloads.
    func createRecoveryKey(
        label: String,
        password: String,
        repository: Repository,
        gitDB: GitDatabase,
        serverConfiguration: ServerConfigurationManager.Configuration
    ) async throws -> CreatedRecoveryKey {
        guard !serverConfiguration.url.isEmpty, !serverConfiguration.caCertificate.isEmpty else {
            throw Error.invalidServerConfiguration
        }

        let normalizedLabel = sanitizeLabel(label)
        let uuid = UUID().uuidString.lowercased()
        let baseName = "\(normalizedLabel)-\(uuid)"
        let recoveryPubPath = "pubkeys/\(baseName).recovery.pub"
        let recoveryAgePath = "pubkeys/\(baseName).recovery.age"

        let p256Key = P256.Signing.PrivateKey()
        let recoveryAgeIdentity = Curve25519.KeyAgreement.PrivateKey()
        let recoveryAgePublic = try Bech32.encode(hrp: "age", data: recoveryAgeIdentity.publicKey.rawRepresentation)
        let recoverySSH = try sshPublicKey(from: p256Key.publicKey, comment: baseName)

        let existingAgeRecipients = try loadAgeRecipientKeys(repository: repository)
        let allAgeRecipients = Array(Set(existingAgeRecipients + [recoveryAgePublic]))
        let epochFiles = try KEKEpochManager(repository: repository).rewrappedEpochFilesIncludingRecipients(allAgeRecipients)

        var files: [(path: String, content: String)] = [
            (path: recoveryPubPath, content: recoverySSH),
            (path: recoveryAgePath, content: recoveryAgePublic),
        ]
        files.append(contentsOf: epochFiles)

        try await gitDB.commitFiles(
            message: "Add recovery key \(normalizedLabel) (\(uuid))",
            files: files
        )
        Self.postRecoveryKeysDidChange()
        try await gitDB.push()

        guard let pinnedHash = ServerConfigurationManager.certificateHash(fromPEM: serverConfiguration.caCertificate) else {
            throw Error.invalidServerConfiguration
        }
        let plaintext = RecoveryBundle.Plaintext(
            version: 1,
            label: label,
            uuid: uuid,
            created: ISO8601DateFormatter().string(from: Date()),
            discoveryURL: normalizeDiscoveryURL(fromGitURL: serverConfiguration.url),
            caSHA256: pinnedHash,
            p256PrivateKeyPEM: p256Key.pemRepresentation,
            agePrivateKey: try Bech32.encode(hrp: "age-secret-key-", data: recoveryAgeIdentity.rawRepresentation).uppercased()
        )
        let envelope = try RecoveryBundle.encrypt(plaintext: plaintext, password: password)
        let envelopeJSON = try RecoveryBundle.envelopeJSONString(envelope)
        let deepLink = try RecoveryBundle.deepLinkString(for: envelope)

        return CreatedRecoveryKey(
            label: label,
            uuid: uuid,
            recoveryPubPath: recoveryPubPath,
            recoveryAgePath: recoveryAgePath,
            envelopeJSON: envelopeJSON,
            deepLink: deepLink
        )
    }

    // Removes a specific recovery key pair from pubkeys/ so compromised or used keys can be revoked.
    func deleteRecoveryKey(
        uuid: String,
        repository: Repository,
        gitDB: GitDatabase
    ) async throws {
        let records = try listRecoveryKeys(repository: repository)
        guard let record = records.first(where: { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }) else {
            throw Error.noMatchingRecoveryKey
        }

        try await gitDB.commitFiles(
            message: "Remove recovery key \(record.label) (\(record.uuid))",
            files: [],
            deletions: [record.pubPath, record.agePath]
        )
        Self.postRecoveryKeysDidChange()
        try await gitDB.push()
    }

    // Recovers repository access by authenticating with the recovery identity once, then rotating back to device identity.
    func recover(
        input: String,
        password: String,
        discoveryURLOverride: String? = nil,
        repositoryPath: String = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path as NSString).appendingPathComponent("replycant-git-db"),
        session: URLSession = .shared,
        progress: ((String, Double) -> Void)? = nil
    ) async throws -> RecoveryResult {
        let repositoryExists = Repository.exists(at: repositoryPath)
        if Self.shouldRejectRecovery(
            isServerConfigured: ServerConfigurationManager.shared.isConfigured,
            repositoryExists: repositoryExists
        ) {
            throw Error.alreadyConfiguredDevice
        }

        progress?("Decrypting recovery bundle...", 5)
        let envelope = try RecoveryBundle.parseEnvelope(from: input)
        let plaintext = try RecoveryBundle.decrypt(envelope: envelope, password: password)

        let discoveryURL = discoveryURLOverride ?? plaintext.discoveryURL
        progress?("Requesting local network access...", 10)
        try await LocalNetworkPermissionManager.shared.requestPermissionIfNeeded(endpointURLs: [discoveryURL])

        progress?("Resolving server discovery...", 15)
        let discovered = try await ServerConfigurationManager.shared.discoverAndConfigure(
            discoveryURLString: discoveryURL,
            expectedCAHash: plaintext.caSHA256,
            session: session
        )

        guard let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw Error.missingPinnedCA
        }

        progress?("Preparing temporary recovery identity...", 25)
        let temporaryIdentity = try ClientIdentityManager.shared.makeTemporaryIdentity(
            privateKeyPEM: plaintext.p256PrivateKeyPEM,
            commonName: "recovery-\(plaintext.uuid.prefix(8))"
        )
        defer {
            try? ClientIdentityManager.shared.deleteTemporaryIdentity()
        }

        try MTLSTransport.shared.configure(clientIdentity: temporaryIdentity, pinnedCA: pinnedCA)

        progress?("Cloning with recovery identity...", 35)
        do {
            try await RepositoryBootstrap.clone(
                serverURL: discovered.url,
                repositoryPath: repositoryPath
            ) { message, cloneProgress in
                progress?(message, RepositoryBootstrap.scaled(cloneProgress, into: 35...70))
            }
        } catch {
            throw Self.mapRecoveryAuthError(error)
        }

        let repository = try await MainActor.run {
            try RepositoryManager.shared.getRepository()
        }
        let gitDB = try await MainActor.run {
            try GitDBManager.shared.getGitDB()
        }
        let ageIdentity = try parseRecoveryAgePrivateKey(plaintext.agePrivateKey)
        let ownDeviceName = normalizedDeviceName()
        let ownDeviceUUID = UUID().uuidString.lowercased()
        let ownPublicKey = try ClientIdentityManager.shared.sshPublicKey(comment: "\(ownDeviceName)-\(ownDeviceUUID)")
        let ownAgePublic = try ClientIdentityManager.shared.agePublicKey()
        let ownPubPath = "pubkeys/\(ownDeviceName)-\(ownDeviceUUID).pub"
        let ownAgePath = "pubkeys/\(ownDeviceName)-\(ownDeviceUUID).age"

        progress?("Re-wrapping encryption keys for this device...", 70)
        let existingAgeRecipients = try loadAgeRecipientKeys(repository: repository)
        let allRecipients = Array(Set(existingAgeRecipients + [ownAgePublic]))
        let epochFiles = try KEKEpochManager(
            repository: repository,
            ageIdentityLoader: { ageIdentity }
        ).rewrappedEpochFilesIncludingRecipients(allRecipients)

        var files: [(path: String, content: String)] = [
            (path: ownPubPath, content: ownPublicKey),
            (path: ownAgePath, content: ownAgePublic),
        ]
        files.append(contentsOf: epochFiles)
        try await gitDB.commitFilesWithoutSync(
            message: "Recover device key for \(ownDeviceName) (\(ownDeviceUUID))",
            files: files
        )
        progress?("Pushing recovered device key...", 75)
        do {
            try await gitDB.push()
        } catch {
            throw Self.mapRecoveryAuthError(error)
        }

        progress?("Building media index...", 80)
        try await RepositoryBootstrap.hydrateIndex(
            resetDatabase: true
        ) { message, hydrateProgress in
            progress?(message, RepositoryBootstrap.scaled(hydrateProgress, into: 80...99))
        }

        guard let primaryIdentity = ClientIdentityManager.shared.loadSecIdentity() else {
            throw Error.missingClientIdentity
        }
        try MTLSTransport.shared.configure(clientIdentity: primaryIdentity, pinnedCA: pinnedCA)

        progress?("Recovery complete.", 100)
        return RecoveryResult(
            usedRecoveryLabel: plaintext.label,
            usedRecoveryUUID: plaintext.uuid,
            discoveredServerURL: discovered.url
        )
    }

    // Parses recovery key filenames of form pubkeys/<label>-<uuid>.recovery.pub.
    private func parseRecoveryKeyName(path: String) -> (label: String, uuid: String)? {
        let fileName = (path as NSString).lastPathComponent
        guard fileName.hasSuffix(".recovery.pub") else {
            return nil
        }
        let stripped = String(fileName.dropLast(".recovery.pub".count))
        let uuidLength = 36
        guard stripped.count > uuidLength else {
            return nil
        }
        let uuidStart = stripped.index(stripped.endIndex, offsetBy: -uuidLength)
        let separatorIndex = stripped.index(before: uuidStart)
        guard stripped[separatorIndex] == "-" else {
            return nil
        }
        let label = String(stripped[..<separatorIndex])
        let uuid = String(stripped[uuidStart...])
        guard !label.isEmpty, UUID(uuidString: uuid) != nil else {
            return nil
        }
        return (label, uuid)
    }

    // Loads repository age recipients so epoch re-wrap keeps every already-authorized client decryptable.
    private func loadAgeRecipientKeys(repository: Repository) throws -> [String] {
        let files = try repository.listFiles(in: "pubkeys")
        let ageFiles = files.filter { $0.hasSuffix(".age") }
        return try ageFiles.map { try repository.readFile(at: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // Normalizes labels into filename-safe prefixes for deterministic pubkey path generation.
    private func sanitizeLabel(_ label: String) -> String {
        let lower = label.lowercased()
        let replaced = lower.replacingOccurrences(of: " ", with: "-")
        let safe = replaced.replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        return safe.isEmpty ? "recovery" : safe
    }

    // Converts gitd origin into caserver discovery URL used by recovery bootstrap.
    private func normalizeDiscoveryURL(fromGitURL gitURL: String) -> String {
        guard var components = URLComponents(string: gitURL), let host = components.host else {
            return gitURL
        }
        components.scheme = components.scheme == "mtls+https" ? "http" : "http"
        components.user = nil
        components.password = nil
        components.host = host
        components.port = 8080
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? gitURL
    }

    // Formats a CryptoKit P-256 public key into SSH ecdsa-sha2-nistp256 form for gitd auth lookup.
    private func sshPublicKey(from publicKey: P256.Signing.PublicKey, comment: String) throws -> String {
        let keyType = "ecdsa-sha2-nistp256"
        let curveName = "nistp256"
        let publicKeyData = publicKey.x963Representation
        var keyData = Data()

        let keyTypeData = Data(keyType.utf8)
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(keyTypeData.count).bigEndian) { Array($0) })
        keyData.append(keyTypeData)

        let curveData = Data(curveName.utf8)
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(curveData.count).bigEndian) { Array($0) })
        keyData.append(curveData)

        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(publicKeyData.count).bigEndian) { Array($0) })
        keyData.append(publicKeyData)

        return "ecdsa-sha2-nistp256 \(keyData.base64EncodedString()) \(comment)"
    }

    // Parses age secret keys from the recovery payload so epoch files can be decrypted once during recovery.
    private func parseRecoveryAgePrivateKey(_ ageSecretKey: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        let decoded = try Bech32.decode(ageSecretKey.lowercased())
        guard decoded.hrp == "age-secret-key-" else {
            throw Error.malformedRecoveryAgeKey
        }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: decoded.data)
    }

    // Produces stable path-safe names for recovered device key files.
    private func normalizedDeviceName() -> String {
        UIDevice.current.name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .lowercased()
    }

    // Broadcasts local key-set changes so Settings can drop or restore the
    // recovery warning without waiting for the next app launch.
    static func postRecoveryKeysDidChange(to center: NotificationCenter = .default) {
        center.post(name: .recoveryKeysDidChange, object: nil)
    }
}

// Broadcasts recovery-key create/delete so the Settings badge can refresh
// immediately after the local repository commit succeeds.
extension Notification.Name {
    static let recoveryKeysDidChange = Notification.Name("recoveryKeysDidChange")
}
