import Foundation
import GitDB
import LibGit2

/// The already-paired device's work after it scans a new device's QR.
///
/// Lives outside the SwiftUI view so commit+push can hop off MainActor. A
/// Task started from the view inherits MainActor in Swift 5, and wrapping
/// the view method in Task.detached hops right back.
enum DeviceLinking {
    /// Why a grant cannot start. Surfaces as the linking error screen.
    enum Error: Swift.Error, LocalizedError {
        case noMTLSCredentials

        // Tells the user to finish first-device setup when this phone
        // has no client identity or pinned CA to push with.
        var errorDescription: String? {
            switch self {
            case .noMTLSCredentials:
                return "mTLS credentials not configured. Please complete initial setup first."
            }
        }
    }

    /// Injected grant steps so tests can prove isolation and authorize
    /// branching without a real repository or gitd.
    ///
    /// Joining the tailnet is not a step here. The key write goes through
    /// GitDB's durable commit, which waits for the node and publishes in
    /// one locked operation, so a scan made too early cannot leave a key
    /// commit that was never pushed.
    struct Operations: Sendable {
        var addDeviceKey: @Sendable (
            _ pubkey: String,
            _ agePubkey: String,
            _ name: String,
            _ uuid: String,
            _ onProgress: @Sendable (String) -> Void
        ) async throws -> Void

        var authorize: @Sendable (
            _ pairingSecret: String,
            _ onProgress: @Sendable (String) -> Void
        ) async throws -> Void
    }

    /// Commits the scanned keys, pushes them, then asks gitd to seal the new
    /// device's join record under the secret from its QR.
    ///
    /// Add-keys is the freeze: it is synchronous libgit2, including the
    /// tailnet session hop inside the durable commit. It always runs in a
    /// detached task so a MainActor caller cannot block the UI for the
    /// network round trip.
    static func grantAccess(
        pubkey: String,
        agePubkey: String,
        name: String,
        uuid: String,
        pairingSecret: String,
        operations: Operations = .live,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try await operations.addDeviceKey(
                pubkey,
                agePubkey,
                name,
                uuid,
                onProgress
            )
        }.value

        try await operations.authorize(pairingSecret, onProgress)
    }

    /// Adds both identity keys and re-wraps KEK epochs so the new device
    /// can decrypt existing encrypted content after it clones.
    static func addDeviceKeyToRepository(
        pubkey: String,
        agePubkey: String,
        name: String,
        uuid: String,
        onProgress: @Sendable (String) -> Void
    ) async throws {
        onProgress("Adding device key...")
        try ensureMTLSTransportConfigured()

        let gitDB = try await MainActor.run {
            try GitDBManager.shared.getGitDB()
        }

        let fileName = "\(name)-\(uuid).pub"
        let pubkeyPath = "pubkeys/\(fileName)"
        let agePath = "pubkeys/\(name)-\(uuid).age"

        log("Adding device key: \(pubkeyPath)", context: "DeviceLinking")

        // Recipient lists and epoch re-wrap are read from the commit the
        // durable write just verified. Doing that before the HEAD check
        // would publish a wrap of a history the push can no longer extend.
        try await gitDB.durableCommit(
            message: "Add device key for \(name) (\(uuid))"
        ) { repository in
            let existingRecipientAgePubkeys = try loadAgeRecipientKeys(
                repository: repository
            )
            let allRecipientAgePubkeys = Array(
                Set(existingRecipientAgePubkeys + [agePubkey])
            )
            let epochFiles = try KEKEpochManager(repository: repository)
                .rewrappedEpochFilesIncludingRecipients(allRecipientAgePubkeys)

            var files: [(path: String, content: String)] = [
                (path: pubkeyPath, content: pubkey),
                (path: agePath, content: agePubkey)
            ]
            files.append(contentsOf: epochFiles)
            return GitFileChange(files: files)
        }

        log("Successfully added and pushed device key", context: "DeviceLinking")
    }

    /// Relays the scanned secret to gitd so the waiting device can join.
    ///
    /// The waiting device cannot reach gitd yet. This device already has an
    /// authenticated path, so its job is to hand gitd the secret from the QR.
    static func authorizeTailnetPairing(
        pairingSecret: String,
        onProgress: @Sendable (String) -> Void
    ) async throws {
        onProgress("Authorizing on your library's network...")

        guard let serverURL = ServerConfigurationManager.shared.loadURL() else {
            throw PairingAuthorization.AuthorizationError.invalidServerURL
        }
        try await PairingAuthorization.publish(
            pairingSecret: pairingSecret,
            serverURL: serverURL,
            session: try await PairingAuthorization.session()
        )
        log(
            "Published pairing record for the scanned device",
            context: "DeviceLinking"
        )
    }

    // Loads repository age public keys so epoch re-wrap includes every
    // currently authorized device.
    private static func loadAgeRecipientKeys(
        repository: Repository
    ) throws -> [String] {
        let files = try repository.listFiles(in: "pubkeys")
        let ageFiles = files.filter { $0.hasSuffix(".age") }
        return try ageFiles.map {
            try repository.readFile(at: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // Registers the mTLS transport with libgit2 before the grant push.
    private static func ensureMTLSTransportConfigured() throws {
        guard let identity = ClientIdentityManager.shared.loadSecIdentity(),
              let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate()
        else {
            throw Error.noMTLSCredentials
        }

        try MTLSTransport.shared.configure(
            clientIdentity: identity,
            pinnedCA: pinnedCA
        )
    }
}

extension DeviceLinking.Operations {
    /// Production grant: publish the keys, then ask gitd to seal the
    /// pairing record. The publish waits for the tailnet itself.
    static var live: DeviceLinking.Operations {
        DeviceLinking.Operations(
            addDeviceKey: { pubkey, agePubkey, name, uuid, onProgress in
                try await DeviceLinking.addDeviceKeyToRepository(
                    pubkey: pubkey,
                    agePubkey: agePubkey,
                    name: name,
                    uuid: uuid,
                    onProgress: onProgress
                )
            },
            authorize: { pairingSecret, onProgress in
                try await DeviceLinking.authorizeTailnetPairing(
                    pairingSecret: pairingSecret,
                    onProgress: onProgress
                )
            }
        )
    }
}
