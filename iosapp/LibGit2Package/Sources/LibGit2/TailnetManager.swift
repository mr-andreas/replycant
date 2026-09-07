import Foundation
import Network
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

    /// Single-use and short-lived. Absent when rejoining, because the node's
    /// key material persists in `stateDirectory` and registering again would
    /// need a credential the deployment has already retired.
    public let preauthKey: String?

    /// Name this device appears under in the tailnet.
    public let hostName: String


    public init(
        headscaleHost: String,
        headscalePort: UInt16 = 443,
        preauthKey: String?,
        hostName: String
    ) {
        self.headscaleHost = headscaleHost
        self.headscalePort = headscalePort
        self.preauthKey = preauthKey
        self.hostName = hostName
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

    /// How this device is currently connected, for the settings screen.
    func status() async throws -> TailnetStatusReport
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
    private let logger: (@Sendable (String) -> Void)?

    private var shim: HeadscaleControlShim?
    private var node: TailscaleNode?

    /// - Parameter stateDirectory: where tsnet persists the node's machine key
    ///   and peer state. Must survive app launches, or every start would
    ///   register a new node and the deployment would accumulate dead ones.
    public init(stateDirectory: URL, logger: (@Sendable (String) -> Void)? = nil) {
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
        clientIdentity: SecIdentity,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        await shutDown()

        logger?("tailnet: starting control shim for \(request.headscaleHost):\(request.headscalePort)")
        onProgress?("Opening a secure path to the server...")

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
        logger?("tailnet: shim listening at \(controlURL)")

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
            let nodeLogger = logger.map { emit in
                TailscaleLogBridge(emit: emit)
            }
            logger?("tailnet: bringing node up as \(request.hostName); preauthKey=\(request.preauthKey != nil)")
            onProgress?("Waiting for the control plane to accept this device...")
            let node = try TailscaleNode(config: configuration, logger: nodeLogger)
            try await node.up()
            self.node = node
        } catch {
            logger?("tailnet: node.up failed: \(error)")
            shim.stop()
            self.shim = nil
            throw error
        }

        await installTailnetControlRoute(on: shim, request: request)

        isJoined = true
        logger?("tailnet: joined as \(request.hostName) via \(request.headscaleHost)")
        onProgress?("Connected to your library's network")
    }

    /// Points the shim at gitd's in-tailnet control relay.
    ///
    /// Only possible after the node is up, because the route runs through the
    /// node's own SOCKS5 proxy. From here on the device reaches the control
    /// plane over WireGuard, which is what turns the hosted relay from
    /// something every session depends on into a bootstrap step.
    ///
    /// Failures are logged rather than thrown: the relay path still works, so
    /// a deployment without the in-tailnet relay keeps its previous behaviour
    /// instead of failing to join.
    private func installTailnetControlRoute(
        on shim: HeadscaleControlShim,
        request: TailnetJoinRequest
    ) async {
        guard let node else { return }
        do {
            let loopback = try await node.loopback()
            guard let ip = loopback.ip, let port = loopback.port,
                  let proxyPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                logger?("tailnet: node exposed no usable SOCKS proxy; control traffic stays on the relay")
                return
            }
            try shim.setTailnetRoute(HeadscaleControlShim.TailnetRoute(
                host: Self.gitdHost,
                port: Self.gitdControlPort,
                socksProxy: .hostPort(host: NWEndpoint.Host(ip), port: proxyPort),
                // tsnet's SOCKS5 listener always authenticates as this user,
                // with the loopback credential as the password.
                socksUsername: "tsnet",
                socksPassword: loopback.proxyCredential
            ))
        } catch {
            logger?("tailnet: in-tailnet control path unavailable, staying on the relay: \(error)")
        }
    }

    /// MagicDNS name gitd registers on the tailnet. Pinned rather than
    /// delivered in a pairing record so a QR and a certificate SAN cannot
    /// drift.
    static let gitdHost = "gitd.replycant.internal"

    /// The port gitd relays control-plane traffic on inside the tailnet.
    ///
    /// Pinned here rather than delivered in the pairing record because it is a
    /// property of the gitd build, not of the deployment, and a device only
    /// ever talks to a gitd from the same release.
    static let gitdControlPort: UInt16 = 8444

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

    /// What to show the user about this device's connection.
    ///
    /// Reads the node's own view rather than tracking state here, because the
    /// node's connectivity changes underneath the app - a peer going offline, a
    /// DERP region changing - with nothing to notify us. The control route
    /// comes from the shim, which is the only thing that knows which path the
    /// last control session took.
    public func status() async throws -> TailnetStatusReport {
        guard let node else {
            throw TailnetError.notJoined
        }
        return try TailnetStatusReport.decode(
            try await node.statusJSON(),
            controlRoute: shim?.lastRoute
        )
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

/// Forwards TailscaleKit lines into the app log. `logger: nil` is what
/// left a hung NeedsLogin looking like tsnet had gone silent.
private struct TailscaleLogBridge: LogSink, Sendable {
    let emit: @Sendable (String) -> Void

    var logFileHandle: Int32? { nil }

    func log(_ message: String) {
        emit("tsnet: \(message)")
    }
}
