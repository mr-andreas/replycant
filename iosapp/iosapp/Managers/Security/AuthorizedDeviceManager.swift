import Foundation
import GitDB
import LibGit2

// Lists devices authorized in pubkeys/ and removes one of them.
// Removal publishes the key deletion and a new encryption epoch in
// one commit, so the device loses server access and cannot read
// photos added afterwards.
final class AuthorizedDeviceManager: Sendable {
    // One authorized device derived from a key set, so Settings can
    // show who has access and which row is this phone.
    struct DeviceRecord: Equatable {
        let name: String
        let uuid: String?
        let path: String
        let isCurrentDevice: Bool
    }

    // Names revocation failures so the device list can tell a missing
    // key apart from an attempt to remove this phone.
    enum Error: Swift.Error, Equatable, LocalizedError {
        case deviceNotFound
        case cannotRevokeCurrentDevice

        // Tells the user whether the device is already gone or is this phone.
        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "That device is no longer authorized."
            case .cannotRevokeCurrentDevice:
                return "This device cannot remove itself."
            }
        }
    }

    // Lists every device key set, leaving recovery keys out, so the
    // screen shows phones and computers rather than backup credentials.
    func listDevices(repository: Repository) throws -> [DeviceRecord] {
        let currentIdentity = currentDeviceSSHIdentity()
        let epochs = KEKEpochManager(repository: repository)
        let records = try KeySet.readAll(in: repository).compactMap { stored -> DeviceRecord? in
            guard stored.keySet.spec.type == KeySet.typeDevice else {
                return nil
            }
            let identity = slugIdentity(stored.keySet.metadata.name)
            let kek = stored.keySet.spec.displayName.flatMap { sealed in
                try? epochs.loadKEK(epoch: sealed.kekEpoch)
            }
            return DeviceRecord(
                name: stored.keySet.resolvedDisplayName(kek: kek),
                uuid: identity.uuid,
                path: stored.path,
                isCurrentDevice: sshIdentity(of: stored.keySet.spec.mtlsPublicKey) == currentIdentity
                    && currentIdentity != nil
            )
        }
        return records.sorted { lhs, rhs in
            if lhs.isCurrentDevice != rhs.isCurrentDevice {
                return lhs.isCurrentDevice
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.path < rhs.path
        }
    }

    // Builds the commit that drops one device and starts the next epoch
    // for everyone still listed, including recovery keys. Kept separate
    // from the push so tests can check the change without a server.
    func revocationChange(
        path: String,
        repository: Repository
    ) throws -> GitFileChange {
        let devices = try listDevices(repository: repository)
        guard let device = devices.first(where: { $0.path == path }) else {
            throw Error.deviceNotFound
        }
        guard !device.isCurrentDevice else {
            throw Error.cannotRevokeCurrentDevice
        }
        let recipients = try remainingRecipientAgePubkeys(
            repository: repository,
            excluding: device.path
        )
        let epochFiles = try KEKEpochManager(repository: repository)
            .nextEpochFiles(recipientAgePubkeys: recipients)
        return GitFileChange(files: epochFiles, deletions: [device.path])
    }

    // Publishes a revocation only when this phone's copy matches the
    // server. The key list is read again inside the commit, so a device
    // another phone just removed cannot be wrapped into a stale epoch.
    func revokeDevice(path: String, gitDB: GitDatabase) async throws {
        let identity = slugIdentity(stem(of: path))
        let message: String
        if let uuid = identity.uuid {
            message = "Remove device \(identity.name) (\(uuid))"
        } else {
            message = "Remove device \(identity.name)"
        }
        try await gitDB.durableCommit(message: message) { repository in
            try self.revocationChange(path: path, repository: repository)
        }
    }

    // Fills in this device's sealed name after a server migration, which
    // cannot write one. Other key sets are left alone: this phone does
    // not know what they are called.
    func ownDisplayNameBackfill(
        repository: Repository,
        displayName: String,
        ownSSHPublicKey: String
    ) throws -> (path: String, content: String)? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ownIdentity = sshIdentity(of: ownSSHPublicKey) else {
            return nil
        }
        guard let stored = try KeySet.readAll(in: repository).first(where: { item in
            item.keySet.spec.type == KeySet.typeDevice
                && sshIdentity(of: item.keySet.spec.mtlsPublicKey) == ownIdentity
        }) else {
            return nil
        }
        if stored.keySet.spec.displayName != nil {
            return nil
        }
        let current = try KEKEpochManager(repository: repository).loadCurrentKEK()
        var updated = stored.keySet
        updated.spec.displayName = try KeySet.encryptDisplayName(
            kek: current.kek,
            epoch: current.epoch,
            name: updated.metadata.name,
            plaintext: trimmed
        )
        return (stored.path, try updated.yaml())
    }

    // Splits a slug of the form <name>-<uuid>. The first device's key
    // has no UUID, and a name may itself contain hyphens, so only a
    // trailing UUID is peeled off.
    private func slugIdentity(_ slug: String) -> (name: String, uuid: String?) {
        let uuidLength = 36
        guard slug.count > uuidLength + 1 else {
            return (slug, nil)
        }
        let uuidStart = slug.index(slug.endIndex, offsetBy: -uuidLength)
        let separator = slug.index(before: uuidStart)
        guard slug[separator] == "-" else {
            return (slug, nil)
        }
        let name = String(slug[..<separator])
        let uuid = String(slug[uuidStart...])
        guard !name.isEmpty, UUID(uuidString: uuid) != nil else {
            return (slug, nil)
        }
        return (name, uuid)
    }

    private func stem(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // Collects age recipients that should still decrypt, including
    // recovery keys, and drops the device being removed.
    private func remainingRecipientAgePubkeys(
        repository: Repository,
        excluding excludedPath: String?
    ) throws -> [String] {
        try KeySet.readAll(in: repository)
            .filter { $0.path != excludedPath }
            .map { $0.keySet.spec.agePublicKey.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // The SSH key is what mTLS checks, so it is how this phone recognizes
    // its own key set. The comment is not part of that identity.
    private func currentDeviceSSHIdentity() -> String? {
        guard let line = try? ClientIdentityManager.shared.sshPublicKey() else {
            return nil
        }
        return sshIdentity(of: line)
    }

    // Reduces an SSH public-key line to its type and key blob so two
    // files for the same device still match when their comments differ.
    private func sshIdentity(of line: String) -> String? {
        let parts = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count >= 2 else {
            return nil
        }
        return "\(parts[0]) \(parts[1])"
    }
}
