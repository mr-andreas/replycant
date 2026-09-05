import Foundation
import Security
import TailscaleKit

/// Everything the device needs to join a deployment's tailnet.
///
/// Delivered in one sealed pairing record, because a device that has never
/// paired has no way to fetch any of it: it does not know the CA, cannot reach
/// the control plane, and holds no tailnet credential.
public struct TailnetJoinRequest: Sendable {
    /// hsproxy's hostname. Also what the shim verifies TLS against, so it must
    /// be a name the certificate was issued for.
    public let headscaleHost: String
    public let headscalePort: UInt16

    /// MagicDNS name and base domain gitd answers on, so the app can rebuild
    /// its server URL without reopening the pairing record.
    public let gitdTailnetName: String
    public let baseDomain: String

    /// Single-use and short-lived. Absent when rejoining, because the node's
    /// key material persists in `stateDirectory` and registering again would
    /// need a credential the deployment has already retired.
    public let preauthKey: String?

    /// Name this device appears under in the tailnet.
    public let hostName: String

    public init(
        headscaleHost: String,
        headscalePort: UInt16 = 443,
        gitdTailnetName: String,
        baseDomain: String,
        preauthKey: String?,
        hostName: String
    ) {
        self.headscaleHost = headscaleHost
        self.headscalePort = headscalePort
        self.gitdTailnetName = gitdTailnetName
        self.baseDomain = baseDomain
        self.preauthKey = preauthKey
        self.hostName = hostName
    }

    /// The URL gitd is reachable at once the device is on the tailnet.
    ///
    /// MagicDNS resolves this inside the tailnet and gitd's certificate carries
    /// the matching SAN, so the existing mTLS transport works unchanged.
    public var gitdURL: String {
        "mtls+https://\(gitdTailnetName).\(baseDomain)"
    }
}

/// The bits of a running tailnet node the rest of the app needs.
///
/// A protocol so the session-routing and lifecycle logic can be tested without
/// standing up a real WireGuard node, which no unit test can do.
public protocol TailnetNodeProviding: AnyObject, Sendable {
    /// Installs this node's SOCKS5 proxy on a session configuration.
    func apply(to configuration: URLSessionConfiguration) async throws

    /// This node's tailnet addresses, for diagnostics.
    func addresses() async throws -> (ip4: String?, ip6: String?)

    func shutDown() async
}

/// Owns the device's membership in one deployment's tailnet.
///
/// All gitd traffic moves onto the tailnet, so this has to be up before any
/// request is issued. Two pieces make that work together:
///
/// - A `HeadscaleControlShim`, because TailscaleKit accepts a control URL but
///   offers no way to pin a private CA or present a client certificate for it.
/// - A `TailscaleNode` pointed at that shim, whose SOCKS5 loopback proxy every
///   URLSession then dials through.
///
/// A userspace node only runs while the app does. Photo sync and periodic sync
/// are already foreground-only `Task` work, so nothing regresses, but it does
/// mean joining is part of app startup rather than a one-time setup step.
public actor TailnetManager: TailnetNodeProviding {
    public enum TailnetError: Error, Equatable {
        case notJoined
        case missingCredentials
        case controlPlaneUnavailable(String)
    }

    private let stateDirectory: URL
    private let logger: ((String) -> Void)?

    private var shim: HeadscaleControlShim?
    private var node: TailscaleNode?

    /// - Parameter stateDirectory: where tsnet persists the node's machine key
    ///   and peer state. Must survive app launches, or every start would
    ///   register a new node and the deployment would accumulate dead ones.
    public init(stateDirectory: URL, logger: ((String) -> Void)? = nil) {
        self.stateDirectory = stateDirectory
        self.logger = logger
    }

    public private(set) var isJoined = false

    /// Brings the tailnet up, replacing any node already running.
    ///
    /// Replacing rather than refusing matters because a user can re-pair a
    /// device: the old node would otherwise keep running with a credential the
    /// deployment has just revoked.
    ///
    /// Returns only once the node is up, so the caller can safely issue
    /// requests immediately afterwards instead of racing the join.
    public func join(
        _ request: TailnetJoinRequest,
        pinnedCA: SecCertificate,
        clientIdentity: SecIdentity
    ) async throws {
        await shutDown()

        let shim = HeadscaleControlShim(
            upstreamHost: request.headscaleHost,
            upstreamPort: request.headscalePort,
            pinnedCA: pinnedCA,
            clientIdentity: clientIdentity,
            logger: logger
        )
        try await shim.start()
        guard let controlURL = shim.controlURL else {
            shim.stop()
            throw TailnetError.controlPlaneUnavailable("shim started without a control URL")
        }
        self.shim = shim

        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        // Not ephemeral: an ephemeral node is removed from the deployment when
        // it goes offline, and this one goes offline every time the app is
        // suspended.
        let configuration = Configuration(
            hostName: request.hostName,
            path: stateDirectory.path,
            authKey: request.preauthKey,
            controlURL: controlURL,
            ephemeral: false
        )

        do {
            let node = try TailscaleNode(config: configuration, logger: nil)
            try await node.up()
            self.node = node
        } catch {
            shim.stop()
            self.shim = nil
            throw error
        }

        isJoined = true
        logger?("tailnet: joined as \(request.hostName) via \(request.headscaleHost)")
    }

    public func apply(to configuration: URLSessionConfiguration) async throws {
        guard let node else {
            throw TailnetError.notJoined
        }
        try await configuration.proxyVia(node)
    }

    public func addresses() async throws -> (ip4: String?, ip6: String?) {
        guard let node else {
            throw TailnetError.notJoined
        }
        return try await node.addrs()
    }

    /// Takes the node and the shim down.
    ///
    /// `close()` rather than `down()`: upstream's `down()` calls `tailscale_up`
    /// (libtailscale bug), so it brings the node up again instead of stopping
    /// it.
    ///
    /// Failures are logged rather than thrown. This runs on the way out of a
    /// join that failed and on app teardown, where there is nothing useful a
    /// caller could do and refusing to finish would leak the shim's listener.
    public func shutDown() async {
        if let node {
            do {
                try await node.close()
            } catch {
                logger?("tailnet: failed to close the node cleanly: \(error)")
            }
        }
        node = nil

        shim?.stop()
        shim = nil
        isJoined = false
    }
}
