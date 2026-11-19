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
        case invalidDeviceName

        // Tells the user to finish first-device setup when this phone
        // has no client identity or pinned CA to push with.
        var errorDescription: String? {
            switch self {
            case .noMTLSCredentials:
                return "mTLS credentials not configured. Please complete initial setup first."
            case .invalidDeviceName:
                return "That device name cannot be saved. Rename the device and try again."
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
            _ displayName: String?,
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
        displayName: String? = nil,
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
                displayName,
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
        displayName: String? = nil,
        onProgress: @Sendable (String) -> Void
    ) async throws {
        onProgress("Adding device key...")
        try ensureMTLSTransportConfigured()

        let gitDB = try await MainActor.run {
            try GitDBManager.shared.getGitDB()
        }

        let metadataName = try metadataName(slug: name, uuid: uuid)
        let shown = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plaintext = (shown?.isEmpty == false) ? shown! : metadataName

        log("Adding device key: \(KeySet.path(name: metadataName))", context: "DeviceLinking")

        // Recipient lists and epoch re-wrap are read from the commit the
        // durable write just verified. Doing that before the HEAD check
        // would publish a wrap of a history the push can no longer extend.
        try await gitDB.durableCommit(
            message: "Add device key for \(name) (\(uuid))"
        ) { repository in
            let epochs = KEKEpochManager(repository: repository)
            let current = try epochs.loadCurrentKEK()
            let sealed = try KeySet.encryptDisplayName(
                kek: current.kek,
                epoch: current.epoch,
                name: metadataName,
                plaintext: plaintext
            )
            let keySet = KeySet(
                apiVersion: KeySet.apiVersionValue,
                kind: KeySet.kindValue,
                metadata: .init(name: metadataName),
                spec: .init(
                    type: KeySet.typeDevice,
                    mtlsPublicKey: pubkey,
                    agePublicKey: agePubkey,
                    displayName: sealed
                )
            )
            let keyFile = (path: KeySet.path(name: metadataName), content: try keySet.yaml())
            let existingRecipientAgePubkeys = try loadAgeRecipientKeys(
                repository: repository
            )
            let allRecipientAgePubkeys = Array(
                Set(existingRecipientAgePubkeys + [agePubkey])
            )
            let epochFiles = try epochs
                .rewrappedEpochFilesIncludingRecipients(allRecipientAgePubkeys)
            let recipients = try epochs.globalRecipientsFile(adding: metadataName)
            return GitFileChange(files: [keyFile, recipients] + epochFiles)
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

    // The QR name is a slug the user can read. The file name also
    // carries the UUID, and it has to be a name gitd will accept.
    private static func metadataName(slug: String, uuid: String) throws -> String {
        let name = "\(KeySet.metadataName(from: slug))-\(uuid.lowercased())"
        guard KeySet.isValidName(name) else {
            throw Error.invalidDeviceName
        }
        return name
    }

    // Loads every key set's age key so the new device joins a wrap
    // the devices already on the library can still open.
    private static func loadAgeRecipientKeys(
        repository: Repository
    ) throws -> [String] {
        try KeySet.readAll(in: repository).map {
            $0.keySet.spec.agePublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
            addDeviceKey: { pubkey, agePubkey, name, uuid, displayName, onProgress in
                try await DeviceLinking.addDeviceKeyToRepository(
                    pubkey: pubkey,
                    agePubkey: agePubkey,
                    name: name,
                    uuid: uuid,
                    displayName: displayName,
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
