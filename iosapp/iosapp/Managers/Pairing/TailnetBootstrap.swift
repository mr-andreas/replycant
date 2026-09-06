import Foundation
import GitDB
import LibGit2
import Security

/// Owns the app's single tailnet node and brings it up when there is one to
/// bring up.
///
/// gitd publishes no host ports, so on a tailnet deployment every request the
/// app makes depends on membership. A userspace node only runs while the app
/// does, which means joining is part of startup rather than a one-time setup
/// step, and anything that issues requests has to wait for it.
///
/// Deployments that were onboarded over the LAN have no tailnet configuration
/// and must keep working untouched, so every entry point here is a no-op when
/// nothing is stored.
actor TailnetBootstrap {
    static let shared = TailnetBootstrap()

    enum BootstrapError: LocalizedError {
        case missingPinnedCA
        case missingDeviceIdentity

        var errorDescription: String? {
            switch self {
            case .missingPinnedCA:
                return "This device has no pinned CA, so it cannot verify the tailnet control plane."
            case .missingDeviceIdentity:
                return "This device has no identity, so the tailnet control plane would reject it."
            }
        }
    }

    private let configurations: TailnetConfigurationManager
    private var manager: TailnetManager?

    init(configurations: TailnetConfigurationManager = .shared) {
        self.configurations = configurations
    }

    /// Where tsnet persists the node's machine key and peer state.
    ///
    /// Application Support rather than Documents: it must survive launches, or
    /// every start would register a new node and the deployment would
    /// accumulate dead ones, but it is not user-visible data.
    static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tailnet", isDirectory: true)
    }

    /// Whether this deployment is reached over a tailnet at all.
    var isConfigured: Bool { configurations.load() != nil }

    /// Brings the tailnet up if this device is paired to one, and does nothing
    /// otherwise.
    ///
    /// Idempotent, because it runs at launch and again before any flow that
    /// must not proceed without connectivity. A rejoin carries no pre-auth key:
    /// the node re-authenticates from the state directory, and the deployment
    /// has already retired the credential from pairing.
    func ensureJoinedIfConfigured() async throws {
        guard let configuration = configurations.load() else { return }
        if let manager, await manager.isJoined { return }

        try await join(configuration: configuration, preauthKey: nil)
    }

    /// Joins for the first time, from a freshly opened pairing record.
    ///
    /// Persists the configuration only after the join succeeds, so a record
    /// that cannot actually be used does not leave the app trying to rejoin a
    /// tailnet it never reached.
    func joinAndPersist(payload: PairingRecord.Payload) async throws {
        let configuration = try TailnetConfigurationManager.from(payload: payload)
        try await join(configuration: configuration, preauthKey: payload.preauthKey)
        configurations.save(configuration)
    }

    /// Takes the node down and forgets the deployment. Used when a device is
    /// unpaired or its state is wiped.
    func leave() async {
        await manager?.shutDown()
        manager = nil
        TailnetSessionRouter.shared.use(nil)
        configurations.clear()
    }

    /// How this device is connected, or nil when there is no tailnet to
    /// describe - a LAN deployment, or a paired device whose node has not come
    /// up yet.
    func status() async -> TailnetStatusReport? {
        guard let manager else { return nil }
        return try? await manager.status()
    }

    private func join(configuration: TailnetConfiguration, preauthKey: String?) async throws {
        guard let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw BootstrapError.missingPinnedCA
        }
        guard let identity = ClientIdentityManager.shared.loadSecIdentity() else {
            throw BootstrapError.missingDeviceIdentity
        }

        let manager = self.manager ?? TailnetManager(
            stateDirectory: Self.stateDirectory,
            logger: { message in log(message, context: "Tailnet") }
        )
        self.manager = manager

        try await manager.join(
            TailnetJoinRequest(
                headscaleHost: configuration.headscaleHost,
                headscalePort: configuration.headscalePort,
                gitdTailnetName: configuration.gitdTailnetName,
                baseDomain: configuration.baseDomain,
                preauthKey: preauthKey,
                // The same identifier the deployment already knows this device
                // by, so a tailnet peer list reads the way the device list does
                // rather than showing an unrelated second name.
                hostName: DeviceIdentifierManager.shared.deviceSpaceIdentifier
            ),
            pinnedCA: pinnedCA,
            clientIdentity: identity
        )

        // Every URLSession the app builds routes through the node's proxy, and
        // the router refuses to hand out a configuration until a node is
        // registered. Registering here rather than at each call site is what
        // keeps a request from silently escaping the tailnet.
        TailnetSessionRouter.shared.use(manager)
    }
}
