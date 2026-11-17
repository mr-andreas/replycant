import CryptoKit
import Foundation
import GitDB
import LibGit2
import UIKit

// Coordinates recovery-key creation and revocation so users can regain repository access after key loss.
// It keeps no mutable state, so a durable write can re-read pubkeys/ from
// the commit it is about to publish without hopping actors.
final class RecoveryKeyManager: Sendable {
    // Captures shareable outputs generated when a recovery key is created.
    struct CreatedRecoveryKey {
        let label: String
        let uuid: String
        let path: String
        let envelopeJSON: String
        let deepLink: String
    }

    // Describes one recovery key detected in pubkeys/ so UI can present actionable state.
    struct RecoveryKeyRecord: Equatable {
        let label: String
        let uuid: String
        let path: String
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
    // On a tailnet, hsproxy refusing to mint (403) is the same verdict, reached
    // after the chain was verified against the bundle's CA hash.
    static func mapRecoveryAuthError(_ error: Swift.Error) -> Swift.Error {
        if case HeadscaleControlShim.ShimError.keyRefused(403) = error {
            return Error.recoveryKeyNotAuthorized
        }
        return MTLSTransportError.indicatesHTTPStatus(401, in: error)
            ? Error.recoveryKeyNotAuthorized
            : error
    }

    // Returns true when at least one marked recovery key exists in pubkeys/.
    func hasRecoveryKey(repository: Repository) throws -> Bool {
        try !listRecoveryKeys(repository: repository).isEmpty
    }

    // Lists recovery key sets. A sealed name is shown when this device
    // can open it; otherwise the slug, which is all a migrated key has.
    func listRecoveryKeys(repository: Repository) throws -> [RecoveryKeyRecord] {
        let epochs = KEKEpochManager(repository: repository)
        return try KeySet.readAll(in: repository)
            .filter { $0.keySet.spec.type == KeySet.typeRecovery }
            .map { stored in
                let identity = labelAndUUID(from: stored.keySet.metadata.name)
                let kek = stored.keySet.spec.displayName.flatMap { sealed in
                    try? epochs.loadKEK(epoch: sealed.kekEpoch)
                }
                return RecoveryKeyRecord(
                    label: stored.keySet.resolvedDisplayName(kek: kek),
                    uuid: identity.uuid,
                    path: stored.path
                )
            }
            .sorted { $0.path < $1.path }
    }

    // Creates a new recovery key, publishes marked pubkeys, re-wraps epochs, and returns share payloads.
    // The re-wrap reads GitDB's repository after it matches the server, so
    // callers no longer pass a repository of their own.
    func createRecoveryKey(
        label: String,
        password: String,
        gitDB: GitDatabase,
        serverConfiguration: ServerConfigurationManager.Configuration,
        tailnetConfiguration: TailnetConfiguration? = TailnetConfigurationManager.shared.load()
    ) async throws -> CreatedRecoveryKey {
        // The bundle names the control plane, the only endpoint a phone with
        // nothing else can reach, so a device that has not joined a tailnet
        // cannot write one.
        guard !serverConfiguration.url.isEmpty,
              !serverConfiguration.caCertificate.isEmpty,
              let tailnetConfiguration else {
            throw Error.invalidServerConfiguration
        }

        let normalizedLabel = sanitizeLabel(label)
        let uuid = UUID().uuidString.lowercased()
        let baseName = "\(normalizedLabel)-\(uuid)"
        let recoveryPath = KeySet.path(name: baseName)
        let shownName = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? normalizedLabel
            : label.trimmingCharacters(in: .whitespacesAndNewlines)

        let p256Key = P256.Signing.PrivateKey()
        let recoveryAgeIdentity = Curve25519.KeyAgreement.PrivateKey()
        let recoveryAgePublic = try Bech32.encode(hrp: "age", data: recoveryAgeIdentity.publicKey.rawRepresentation)
        let recoverySSH = try sshPublicKey(from: p256Key.publicKey, comment: baseName)

        // The epoch re-wrap has to see the commit the push will extend.
        // Wrapping beforehand can publish a key set that already missed
        // a device another phone just added.
        try await gitDB.durableCommit(
            message: "Add recovery key \(normalizedLabel) (\(uuid))"
        ) { repository in
            let epochs = KEKEpochManager(repository: repository)
            let current = try epochs.loadCurrentKEK()
            let sealed = try KeySet.encryptDisplayName(
                kek: current.kek,
                epoch: current.epoch,
                name: baseName,
                plaintext: shownName
            )
            let keyFile = try keySetFile(
                name: baseName,
                type: KeySet.typeRecovery,
                mtls: recoverySSH,
                age: recoveryAgePublic,
                displayName: sealed
            )
            let existingAgeRecipients = try loadAgeRecipientKeys(repository: repository)
            let allAgeRecipients = Array(Set(existingAgeRecipients + [recoveryAgePublic]))
            let epochFiles = try epochs.rewrappedEpochFilesIncludingRecipients(allAgeRecipients)
            return GitFileChange(files: [keyFile] + epochFiles)
        }
        Self.postRecoveryKeysDidChange()

        guard let pinnedHash = ServerConfigurationManager.certificateHash(fromPEM: serverConfiguration.caCertificate) else {
            throw Error.invalidServerConfiguration
        }
        let plaintext = RecoveryBundle.Plaintext(
            version: 1,
            label: label,
            uuid: uuid,
            created: ISO8601DateFormatter().string(from: Date()),
            headscaleURL: tailnetConfiguration.headscaleURL,
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
            path: recoveryPath,
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

        // The paths are read again under the durable write. The name
        // above only exists so a missing key fails before the fetch,
        // and so the commit message still names the key.
        try await gitDB.durableCommit(
            message: "Remove recovery key \(record.label) (\(record.uuid))"
        ) { repository in
            let current = try listRecoveryKeys(repository: repository)
            guard let match = current.first(where: { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }) else {
                throw Error.noMatchingRecoveryKey
            }
            return GitFileChange(deletions: [match.path])
        }
        Self.postRecoveryKeysDidChange()
    }

    // Recovers repository access by authenticating with the recovery identity once, then rotating back to device identity.
    func recover(
        input: String,
        password: String,
        repositoryPath: String = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path as NSString).appendingPathComponent("replycant-git-db"),
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

        progress?("Preparing temporary recovery identity...", 10)
        let temporaryIdentity = try ClientIdentityManager.shared.makeTemporaryIdentity(
            privateKeyPEM: plaintext.p256PrivateKeyPEM,
            commonName: "recovery-\(plaintext.uuid.prefix(8))"
        )
        defer {
            try? ClientIdentityManager.shared.deleteTemporaryIdentity()
        }

        do {
            return try await recoverOverTailnet(
                plaintext: plaintext,
                temporaryIdentity: temporaryIdentity,
                repositoryPath: repositoryPath,
                progress: progress
            )
        } catch {
            // Recovery refuses to start on a configured device, so a half
            // finished attempt must not leave configuration behind, or the
            // user could never retry.
            await TailnetBootstrap.shared.leave()
            ServerConfigurationManager.shared.clearConfiguration()
            throw Self.mapRecoveryAuthError(error)
        }
    }

    // gitd is reachable only over the tailnet, so recovery starts from the
    // control plane the bundle names. hsproxy authorizes the recovery
    // identity like any device and sends the CA in its chain, which the
    // bundle's hash picks out and from then on is pinned.
    private func recoverOverTailnet(
        plaintext: RecoveryBundle.Plaintext,
        temporaryIdentity: SecIdentity,
        repositoryPath: String,
        progress: ((String, Double) -> Void)?
    ) async throws -> RecoveryResult {
        progress?("Joining your library's network...", 15)
        let ca = try await TailnetBootstrap.shared.joinForRecovery(
            headscaleURL: plaintext.headscaleURL,
            caSHA256: plaintext.caSHA256,
            clientIdentity: temporaryIdentity
        )
        try ServerConfigurationManager.shared.configure(
            url: TailnetConfiguration.gitdURL,
            caCertificate: ServerConfigurationManager.pemString(fromDER: SecCertificateCopyData(ca) as Data)
        )

        return try await enroll(
            plaintext: plaintext,
            serverURL: TailnetConfiguration.gitdURL,
            pinnedCA: ca,
            temporaryIdentity: temporaryIdentity,
            repositoryPath: repositoryPath,
            progress: progress,
            afterPush: {
                // hsproxy checks the identity on every control connection, and
                // the recovery key is usually revoked straight after, so the
                // node has to reconnect as this device before that happens.
                progress?("Reconnecting as this device...", 78)
                try await TailnetBootstrap.shared.joinAndPersist(
                    headscaleURL: plaintext.headscaleURL,
                    preauthKey: nil
                )
                // The rejoin reuses this device's node key moments after the
                // recovery node stopped. gitd can still be sending to that
                // process, so the first handshake is lost and the next
                // request, usually revoking the used key, fails. Waiting
                // here is what makes that request succeed. A timeout is
                // logged rather than thrown: the key is already pushed, and
                // throwing would wipe the configuration this recovery just
                // created.
                let reachable = await TailnetBootstrap.shared.waitUntilGitdReachable()
                if !reachable {
                    logError(
                        "gitd was not reachable after rejoining as this device",
                        context: "Recovery"
                    )
                }
            }
        )
    }

    // Clones as the recovery identity, enrolls this device's keys, and hands
    // the transport back to the device identity. `afterPush` runs once this
    // device's key is on the server, the first moment it is authorized.
    private func enroll(
        plaintext: RecoveryBundle.Plaintext,
        serverURL: String,
        pinnedCA: SecCertificate,
        temporaryIdentity: SecIdentity,
        repositoryPath: String,
        progress: ((String, Double) -> Void)?,
        afterPush: () async throws -> Void
    ) async throws -> RecoveryResult {
        try MTLSTransport.shared.configure(clientIdentity: temporaryIdentity, pinnedCA: pinnedCA)

        progress?("Cloning with recovery identity...", 35)
        do {
            try await RepositoryBootstrap.clone(
                serverURL: serverURL,
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
        let shownName = await MainActor.run {
            UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ownDeviceName = KeySet.metadataName(from: shownName)
        let ownDeviceUUID = UUID().uuidString.lowercased()
        let ownMetadataName = "\(ownDeviceName)-\(ownDeviceUUID)"
        let ownPublicKey = try ClientIdentityManager.shared.sshPublicKey(comment: ownMetadataName)
        let ownAgePublic = try ClientIdentityManager.shared.agePublicKey()

        progress?("Re-wrapping encryption keys for this device...", 70)
        let epochs = KEKEpochManager(
            repository: repository,
            ageIdentityLoader: { ageIdentity }
        )
        let current = try epochs.loadCurrentKEK()
        let sealed = try KeySet.encryptDisplayName(
            kek: current.kek,
            epoch: current.epoch,
            name: ownMetadataName,
            plaintext: shownName.isEmpty ? ownMetadataName : shownName
        )
        let ownKey = try keySetFile(
            name: ownMetadataName,
            type: KeySet.typeDevice,
            mtls: ownPublicKey,
            age: ownAgePublic,
            displayName: sealed
        )
        let existingAgeRecipients = try loadAgeRecipientKeys(repository: repository)
        let allRecipients = Array(Set(existingAgeRecipients + [ownAgePublic]))
        let epochFiles = try epochs.rewrappedEpochFilesIncludingRecipients(allRecipients)
        let files = [ownKey] + epochFiles
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
        try await afterPush()

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
            discoveredServerURL: serverURL
        )
    }

    // Peels a trailing UUID off a key-set name so the row can show it
    // separately. A name without one keeps the whole slug as its id.
    private func labelAndUUID(from slug: String) -> (label: String, uuid: String) {
        let uuidLength = 36
        guard slug.count > uuidLength + 1 else {
            return (slug, slug)
        }
        let uuidStart = slug.index(slug.endIndex, offsetBy: -uuidLength)
        let separator = slug.index(before: uuidStart)
        guard slug[separator] == "-" else {
            return (slug, slug)
        }
        let label = String(slug[..<separator])
        let uuid = String(slug[uuidStart...])
        guard !label.isEmpty, UUID(uuidString: uuid) != nil else {
            return (slug, slug)
        }
        return (label, uuid)
    }

    // Loads every key set's age key, including recovery keys, so a new
    // epoch stays readable by devices that are not being removed.
    private func loadAgeRecipientKeys(repository: Repository) throws -> [String] {
        try KeySet.readAll(in: repository).map {
            $0.keySet.spec.agePublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // The filename is a slug. The words the user typed are sealed
    // separately, so an empty label still needs a usable file name.
    private func sanitizeLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasToken = trimmed.contains { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }
        guard hasToken else {
            return "recovery"
        }
        return KeySet.metadataName(from: trimmed)
    }

    private func keySetFile(
        name: String,
        type: String,
        mtls: String,
        age: String,
        displayName: KeySet.DisplayName?
    ) throws -> (path: String, content: String) {
        let keySet = KeySet(
            apiVersion: KeySet.apiVersionValue,
            kind: KeySet.kindValue,
            metadata: .init(name: name),
            spec: .init(
                type: type,
                mtlsPublicKey: mtls,
                agePublicKey: age,
                displayName: displayName
            )
        )
        return (KeySet.path(name: name), try keySet.yaml())
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
