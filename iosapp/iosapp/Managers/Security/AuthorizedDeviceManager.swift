import Foundation
import GitDB
import LibGit2

// Lists devices authorized in pubkeys/ and removes one of them.
// Removal publishes the key deletion and a new encryption epoch in
// one commit, so the device loses server access and cannot read
// photos added afterwards.
final class AuthorizedDeviceManager: Sendable {
    // One authorized device derived from pubkeys/, so Settings can show
    // who has access and which row is this phone.
    struct DeviceRecord: Equatable {
        let name: String
        let uuid: String?
        let pubPath: String
        let agePath: String?
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

    // Lists every device key, leaving recovery keys out, so the screen
    // shows phones and computers rather than backup credentials.
    func listDevices(repository: Repository) throws -> [DeviceRecord] {
        let currentIdentity = currentDeviceSSHIdentity()
        let files = try repository.listFiles(in: "pubkeys")
        let pubFiles = files.filter { path in
            path.hasSuffix(".pub") && !path.hasSuffix(".recovery.pub")
        }
        let records = try pubFiles.map { pubPath -> DeviceRecord in
            let identity = deviceIdentity(from: pubPath)
            let content = try repository.readFile(at: pubPath)
            return DeviceRecord(
                name: identity.name,
                uuid: identity.uuid,
                pubPath: pubPath,
                agePath: matchingAgePath(for: pubPath, in: files),
                isCurrentDevice: sshIdentity(of: content) == currentIdentity
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
            return lhs.pubPath < rhs.pubPath
        }
    }

    // Builds the commit that drops one device and starts the next epoch
    // for everyone still listed, including recovery keys. Kept separate
    // from the push so tests can check the change without a server.
    func revocationChange(
        pubPath: String,
        repository: Repository
    ) throws -> GitFileChange {
        let devices = try listDevices(repository: repository)
        guard let device = devices.first(where: { $0.pubPath == pubPath }) else {
            throw Error.deviceNotFound
        }
        guard !device.isCurrentDevice else {
            throw Error.cannotRevokeCurrentDevice
        }
        let recipients = try remainingRecipientAgePubkeys(
            repository: repository,
            excluding: device.agePath
        )
        let epochFiles = try KEKEpochManager(repository: repository)
            .nextEpochFiles(recipientAgePubkeys: recipients)
        var deletions = [device.pubPath]
        if let agePath = device.agePath {
            deletions.append(agePath)
        }
        return GitFileChange(files: epochFiles, deletions: deletions)
    }

    // Publishes a revocation only when this phone's copy matches the
    // server. The key list is read again inside the commit, so a device
    // another phone just removed cannot be wrapped into a stale epoch.
    func revokeDevice(pubPath: String, gitDB: GitDatabase) async throws {
        let identity = deviceIdentity(from: pubPath)
        let message: String
        if let uuid = identity.uuid {
            message = "Remove device \(identity.name) (\(uuid))"
        } else {
            message = "Remove device \(identity.name)"
        }
        try await gitDB.durableCommit(message: message) { repository in
            try self.revocationChange(pubPath: pubPath, repository: repository)
        }
    }

    // Splits pubkeys/<name>-<uuid>.pub. The first device's key has no
    // UUID, and a name may itself contain hyphens, so only a trailing
    // UUID is peeled off.
    private func deviceIdentity(from path: String) -> (name: String, uuid: String?) {
        let fileName = (path as NSString).lastPathComponent
        guard fileName.hasSuffix(".pub") else {
            return (fileName, nil)
        }
        let stripped = String(fileName.dropLast(".pub".count))
        let uuidLength = 36
        guard stripped.count > uuidLength + 1 else {
            return (stripped, nil)
        }
        let uuidStart = stripped.index(stripped.endIndex, offsetBy: -uuidLength)
        let separator = stripped.index(before: uuidStart)
        guard stripped[separator] == "-" else {
            return (stripped, nil)
        }
        let name = String(stripped[..<separator])
        let uuid = String(stripped[uuidStart...])
        guard !name.isEmpty, UUID(uuidString: uuid) != nil else {
            return (stripped, nil)
        }
        return (name, uuid)
    }

    // Pairs a device public key with its age key when one was published.
    // A key with no age file can still be removed from server access.
    private func matchingAgePath(for pubPath: String, in files: [String]) -> String? {
        let agePath = (pubPath as NSString).deletingPathExtension + ".age"
        return files.contains(agePath) ? agePath : nil
    }

    // Collects age recipients that should still decrypt, including
    // recovery keys, and drops the device being removed.
    private func remainingRecipientAgePubkeys(
        repository: Repository,
        excluding excludedAgePath: String?
    ) throws -> [String] {
        let files = try repository.listFiles(in: "pubkeys")
        let ageFiles = files.filter { path in
            path.hasSuffix(".age") && path != excludedAgePath
        }
        let keys = try ageFiles.map { path in
            try repository.readFile(at: path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Array(Set(keys.filter { !$0.isEmpty }))
    }

    // The SSH key is what mTLS checks, so it is how this phone recognizes
    // its own pubkey file. The comment is not part of that identity.
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
