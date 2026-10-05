import Foundation
import Network
import Security
import TailscaleKit

/// Everything the device needs to join a deployment's tailnet.
///
/// Delivered in one sealed pairing record, because a device that has never
/// paired has no way to fetch any of it: it does not know the CA and cannot
/// reach the control plane.
public struct TailnetJoinRequest: Sendable {
    /// hsproxy's hostname. Also what the shim verifies TLS against, so it must
    /// be a name the certificate was issued for.
    public let headscaleHost: String
    public let headscalePort: UInt16

    /// Only the deployment's first device has one, from the CA page. Every
    /// other join starts without a key and mints one through hsproxy if
    /// headscale does not know the node, since the device certificate in
    /// `pubkeys/` is what entitles it to the tailnet.
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

    /// Copies SOCKS settings captured when the node came up, so libgit2
    /// callbacks do not hop onto the node actor from a higher-QoS thread.
    nonisolated func applyCachedProxy(to configuration: URLSessionConfiguration) -> Bool

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
    /// Failures a caller can act on: no node yet, missing identity, or a
    /// control plane / proxy that came up too incomplete to carry traffic.
    public enum TailnetError: Error, Equatable {
        case notJoined
        case missingCredentials
        case controlPlaneUnavailable(String)
        /// Join reached a live node that still could not hand out SOCKS
        /// settings, so later sessions would have no way to reach gitd.
        case missingProxy
    }

    private let stateDirectory: URL
    private let logger: (@Sendable (String) -> Void)?
    /// SOCKS settings captured at join so C callbacks never wait on this actor.
    private let proxyCache = ProxyConfigurationCache()

    private var shim: HeadscaleControlShim?
    private var node: TailscaleNode?

    /// Fed by every node's log so a forgotten running node is noticed.
    private let forgottenNode = TailnetForgottenNodeSignal()
    private var reloginWatch: Task<Void, Never>?
    private var lastRelogin: Date?

    /// How often a running node is checked for having been forgotten.
    static let reloginCheckInterval: Duration = .seconds(5)

    /// The least time between two mints. A device hsproxy refuses, or a
    /// headscale that keeps losing state, must not turn into a key per check.
    static let reloginCooldown: TimeInterval = 30

    /// - Parameter stateDirectory: where tsnet persists the node's machine key
    ///   and peer state. Must survive app launches, or every start would
    ///   register a new node and the deployment would accumulate dead ones.
    public init(stateDirectory: URL, logger: (@Sendable (String) -> Void)? = nil) {
        self.stateDirectory = stateDirectory
        self.logger = logger
    }

    public private(set) var isJoined = false

    /// The CA the control plane verified against. After a join that only knew
    /// the CA's hash, this is how the caller learns the CA to pin.
    public var verifiedCA: SecCertificate? {
        shim?.verifiedCA
    }

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
        trust: HeadscaleControlShim.Trust,
        clientIdentity: SecIdentity,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        await shutDown()

        logger?("tailnet: starting control shim for \(request.headscaleHost):\(request.headscalePort)")
        onProgress?("Opening a secure path to the server...")

        let shim = HeadscaleControlShim(
            upstreamHost: request.headscaleHost,
            upstreamPort: request.headscalePort,
            trust: trust,
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

        do {
            logger?("tailnet: bringing node up as \(request.hostName); preauthKey=\(request.preauthKey != nil)")
            onProgress?("Waiting for the control plane to accept this device...")
            self.node = try await bringUp(
                request,
                controlURL: controlURL,
                shim: shim,
                onProgress: onProgress
            )
        } catch {
            logger?("tailnet: node.up failed: \(error)")
            shim.stop()
            self.shim = nil
            throw error
        }

        await installTailnetControlRoute(on: shim, request: request)

        do {
            guard let node else {
                throw TailnetError.notJoined
            }
            try await snapshotProxy(from: node)
        } catch {
            logger?("tailnet: SOCKS proxy snapshot failed: \(error)")
            await shutDown()
            throw error
        }

        isJoined = true
        logger?("tailnet: joined as \(request.hostName) via \(request.headscaleHost)")
        onProgress?("Connected to your library's network")
        startReloginWatch(request, controlURL: controlURL)
    }

    /// Creates a node pointed at the shim. Not ephemeral: an ephemeral node is
    /// removed from the deployment when it goes offline, and this one goes
    /// offline every time the app is suspended.
    private func makeNode(
        _ request: TailnetJoinRequest,
        controlURL: String,
        authKey: String?
    ) throws -> TailscaleNode {
        let configuration = Configuration(
            hostName: request.hostName,
            path: stateDirectory.path,
            authKey: authKey,
            controlURL: controlURL,
            ephemeral: false
        )
        let sink = TailscaleLogBridge(emit: logger, forgottenNode: forgottenNode)
        return try TailscaleNode(config: configuration, logger: sink)
    }

    /// Brings a node up, minting a key first if it has never logged in.
    ///
    /// A paired or recovering device starts with no key. The key has to be
    /// in place before the node starts: started without one, the node waits
    /// in NeedsLogin inside `tailscale_up`, which libtailscale can neither
    /// cancel nor close, so the join would never return. A node that has
    /// logged in before needs no key; if headscale has since forgotten it,
    /// it keeps reporting Running and the relogin watch takes over.
    private func bringUp(
        _ request: TailnetJoinRequest,
        controlURL: String,
        shim: HeadscaleControlShim,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> TailscaleNode {
        if let key = request.preauthKey {
            return try await upWithKey(request, controlURL: controlURL, key: key)
        }

        if Self.isFirstLogin(stateDirectory: stateDirectory) {
            logger?("tailnet: first login for this node; minting a key")
            onProgress?("Asking your server to let this device in...")
            let key = try await shim.mintPreauthKey()
            return try await upWithKey(request, controlURL: controlURL, key: key)
        }

        let node = try makeNode(request, controlURL: controlURL, authKey: nil)
        do {
            try await node.up()
        } catch {
            try? await node.close()
            throw error
        }
        return node
    }

    private func upWithKey(
        _ request: TailnetJoinRequest,
        controlURL: String,
        key: String
    ) async throws -> TailscaleNode {
        let node = try makeNode(request, controlURL: controlURL, authKey: key)
        do {
            try await node.up()
        } catch {
            try? await node.close()
            throw error
        }
        return node
    }

    /// Whether the node in `stateDirectory` has never logged in, read from the
    /// profile tsnet records once it has. Unreadable state counts as a first
    /// login: an unneeded key is harmless, a missing one hangs the join.
    static func isFirstLogin(stateDirectory: URL) -> Bool {
        let url = stateDirectory.appendingPathComponent("tailscaled.state")
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        return state["_current-profile"] == nil
    }

    private static func needsLogin(_ node: TailscaleNode) async -> Bool {
        guard let data = try? await node.statusJSON(),
              let report = try? TailnetStatusReport.decode(data, controlRoute: nil) else {
            return false
        }
        return report.needsLogin
    }

    /// Keeps a running node on the tailnet when headscale forgets it.
    ///
    /// A forgotten node never reaches NeedsLogin on its own; its map polls
    /// fail with 404 and it keeps reporting Running. Without this, a headscale
    /// wipe would strand every device until its next app launch.
    private func startReloginWatch(_ request: TailnetJoinRequest, controlURL: String) {
        reloginWatch?.cancel()
        // A 404 seen while joining was already answered by the join itself.
        _ = forgottenNode.consume()
        reloginWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reloginCheckInterval)
                guard let self, !Task.isCancelled else { return }
                await self.reloginIfForgotten(request, controlURL: controlURL)
            }
        }
    }

    // Replaces the node with one logged in under a fresh key. Leaves the old
    // node in place when no key can be had, since it may still be serving
    // traffic to peers that have not noticed anything.
    private func reloginIfForgotten(_ request: TailnetJoinRequest, controlURL: String) async {
        guard let node, let shim else { return }
        if let lastRelogin, Date().timeIntervalSince(lastRelogin) < Self.reloginCooldown {
            return
        }
        var forgotten = forgottenNode.consume()
        if !forgotten {
            forgotten = await Self.needsLogin(node)
        }
        guard forgotten else { return }
        lastRelogin = Date()

        logger?("tailnet: headscale forgot this node; minting a key")
        let key: String
        do {
            key = try await shim.mintPreauthKey()
        } catch {
            logger?("tailnet: could not mint a key to rejoin: \(error)")
            return
        }

        try? await node.close()
        self.node = nil
        proxyCache.store(nil)
        isJoined = false
        shim.clearTailnetRoute()

        do {
            let fresh = try await upWithKey(request, controlURL: controlURL, key: key)
            self.node = fresh
            await installTailnetControlRoute(on: shim, request: request)
            try await snapshotProxy(from: fresh)
            isJoined = true
            logger?("tailnet: rejoined as \(request.hostName)")
        } catch {
            logger?("tailnet: rejoin failed: \(error)")
        }
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

    /// Copies SOCKS settings captured at join so C callbacks do not wait on
    /// this actor from a higher-QoS thread.
    nonisolated public func applyCachedProxy(to configuration: URLSessionConfiguration) -> Bool {
        proxyCache.apply(to: configuration)
    }

    /// Reads the SOCKS settings TailscaleKit installs.
    ///
    /// `proxyVia` writes `proxyConfigurations` and leaves the older
    /// `connectionProxyDictionary` empty. Treating that empty dictionary as
    /// a failed join tore the node down on every launch after the first.
    static func capturedProxyConfigurations(
        from configuration: URLSessionConfiguration
    ) -> [ProxyConfiguration]? {
        let configurations = configuration.proxyConfigurations
        return configurations.isEmpty ? nil : configurations
    }

    /// Installs a previously captured SOCKS proxy on a later session.
    static func applyCapturedProxy(
        _ configurations: [ProxyConfiguration],
        to configuration: URLSessionConfiguration
    ) -> Bool {
        guard !configurations.isEmpty else { return false }
        configuration.proxyConfigurations = configurations
        return true
    }

    /// Captures the node's SOCKS settings so later libgit2 and AVFoundation
    /// sessions can install the proxy without an actor hop.
    private func snapshotProxy(from node: TailscaleNode) async throws {
        let probe = URLSessionConfiguration.ephemeral
        try await probe.proxyVia(node)
        guard let configurations = Self.capturedProxyConfigurations(from: probe) else {
            throw TailnetError.missingProxy
        }
        proxyCache.store(configurations)
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
        reloginWatch?.cancel()
        reloginWatch = nil
        if let node {
            do {
                try await node.close()
            } catch {
                logger?("tailnet: failed to close the node cleanly: \(error)")
            }
        }
        node = nil
        proxyCache.store(nil)

        shim?.stop()
        shim = nil
        isJoined = false
    }
}

/// Holds SOCKS settings captured when the node came up so libgit2 callbacks
/// can install the proxy without hopping onto the node actor from a higher-QoS
/// thread.
private final class ProxyConfigurationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [ProxyConfiguration]?

    /// Replaces the snapshot used by later synchronous session builds.
    func store(_ configurations: [ProxyConfiguration]?) {
        lock.lock()
        self.configurations = configurations
        lock.unlock()
    }

    /// Copies the snapshot onto a configuration, or reports that join never
    /// produced one so the caller can refuse to dial directly.
    func apply(to configuration: URLSessionConfiguration) -> Bool {
        lock.lock()
        let configurations = self.configurations
        lock.unlock()
        guard let configurations else { return false }
        return TailnetManager.applyCapturedProxy(configurations, to: configuration)
    }
}

/// Forwards TailscaleKit lines into the app log. `logger: nil` is what
/// left a hung NeedsLogin looking like tsnet had gone silent.
///
/// Also the only place a forgotten running node shows up, so every line is
/// offered to the signal even when the app has no logger.
private struct TailscaleLogBridge: LogSink, Sendable {
    let emit: (@Sendable (String) -> Void)?
    let forgottenNode: TailnetForgottenNodeSignal

    var logFileHandle: Int32? { nil }

    func log(_ message: String) {
        forgottenNode.observe(message)
        emit?("tsnet: \(message)")
    }
}

/// Remembers that headscale answered a map poll with "node not found".
///
/// That 404 is how a running node learns its registration is gone: after a
/// headscale wipe, or after gitd dropped every device node because a key
/// left `pubkeys/`. The node itself retries forever and stays Running.
final class TailnetForgottenNodeSignal: @unchecked Sendable {
    static let marker = "initial fetch failed 404"

    private let lock = NSLock()
    private var fired = false

    func observe(_ line: String) {
        guard line.contains(Self.marker) else { return }
        lock.lock()
        fired = true
        lock.unlock()
    }

    /// Reports whether the node was forgotten since the last call, and clears
    /// it so one 404 costs at most one key.
    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasFired = fired
        fired = false
        return wasFired
    }
}
