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
    private let forgottenNode: TailnetForgottenNodeSignal
    /// tsnet's backend log, the only place a forgotten running node shows up.
    private let backendLog: TailnetLogPipe
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
        let forgottenNode = TailnetForgottenNodeSignal()
        self.forgottenNode = forgottenNode
        self.backendLog = TailnetLogPipe { line in
            forgottenNode.observe(line)
            logger?("tsnet: \(line)")
        }
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
        startReloginWatch()
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
        let sink = TailscaleLogBridge(
            emit: logger,
            forgottenNode: forgottenNode,
            logFileHandle: backendLog.writeHandleForNode()
        )
        return try TailscaleNode(config: configuration, logger: sink)
    }

    /// Brings a node up, minting a key first if it has never logged in.
    ///
    /// A paired or recovering device starts with no key. The key has to be
    /// in place before the node starts: started without one, the node waits
    /// in NeedsLogin inside `tailscale_up`, which libtailscale can neither
    /// cancel nor close, so the join would never return.
    ///
    /// A node that has logged in before starts without a key, so a launch
    /// does not cost one. If headscale still knows it, it comes up on its
    /// own. If its key was expired or headscale forgot it while the app was
    /// closed - a revocation sweep that had not seen this node yet, a wiped
    /// database - it waits in NeedsLogin inside `tailscale_up` too.
    /// The cold-start watch then logs that same node in with a minted key,
    /// which lets `up()` return. The relogin watch started after the join
    /// covers the same events while the node is running.
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
        let watch = Task {
            await self.logInWhileJoining(node: node, shim: shim, onProgress: onProgress)
        }
        defer { watch.cancel() }
        do {
            try await node.up()
        } catch {
            try? await node.close()
            throw error
        }
        return node
    }

    /// Logs a cold-started node back in while `up()` waits on it.
    ///
    /// `up()` reports nothing until the node is Running, and a forgotten node
    /// never gets there by itself, so the node's own status is polled for
    /// NeedsLogin. Runs until `bringUp` cancels it. Mints at most once per
    /// cooldown, because tsnet passes through NeedsLogin while a key login is
    /// still in flight.
    private func logInWhileJoining(
        node: TailscaleNode,
        shim: HeadscaleControlShim,
        onProgress: (@Sendable (String) -> Void)?
    ) async {
        var lastAttempt: Date?
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.coldStartCheckInterval)
            guard !Task.isCancelled else { return }
            let needsLogin = await Self.needsLogin(node)
            guard Self.shouldMint(needsLogin: needsLogin, lastAttempt: lastAttempt, now: Date()) else {
                continue
            }
            lastAttempt = Date()

            logger?("tailnet: headscale does not know this node; minting a key")
            onProgress?("Asking your server to let this device in...")
            do {
                let key = try await shim.mintPreauthKey()
                try await Self.logIn(node: node, key: key)
                logger?("tailnet: logged in again with a new key")
            } catch {
                logger?("tailnet: could not log this node back in: \(error)")
            }
        }
    }

    /// How often a joining node is checked for waiting on a login. Short,
    /// because the whole app is waiting on this join.
    static let coldStartCheckInterval: Duration = .seconds(1)

    /// Whether a node's login state justifies spending a key now.
    static func shouldMint(needsLogin: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard needsLogin else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= reloginCooldown
    }

    /// Logs a node that headscale no longer knows back in, keeping its
    /// machine key and stored prefs.
    ///
    /// Mirrors the desktop and CLI keeper: restarting the backend with a key
    /// logs a node that still has a node key straight in, and one that lands
    /// in NeedsLogin anyway is pushed into the login explicitly, the way
    /// tsnet handles a key on its own first start.
    static func logIn(node: TailscaleNode, key: String) async throws {
        let client = LocalAPIClient(localNode: node, logger: nil)
        try await client.start(options: loginOptions(authKey: key))
        if await needsLogin(node) {
            try await client.startLoginInteractive()
        }
    }

    /// Backend start options carrying only a key. Built by decoding because
    /// TailscaleKit gives `Ipn.Options` no memberwise initializer.
    static func loginOptions(authKey: String) throws -> Ipn.Options {
        let wire = try JSONEncoder().encode(["AuthKey": authKey])
        return try JSONDecoder().decode(Ipn.Options.self, from: wire)
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
        await backendState(node) == "NeedsLogin"
    }

    /// The node's backend state, or nil when its status cannot be read.
    private static func backendState(_ node: TailscaleNode) async -> String? {
        guard let data = try? await node.statusJSON(),
              let report = try? TailnetStatusReport.decode(data, controlRoute: nil) else {
            return nil
        }
        return report.backendState
    }

    /// Keeps a running node on the tailnet when headscale stops accepting it.
    ///
    /// A revocation sweep expires every device node gitd has not seen
    /// authenticate with a current key, and an expired node moves to
    /// NeedsLogin. A node a wiped headscale
    /// forgot never does; its map polls fail with 404 and it keeps reporting
    /// Running. That 404 only shows up in tsnet's backend log, which reaches
    /// the signal through the log pipe. Without this watch, every device
    /// would be stranded until its next launch.
    private func startReloginWatch() {
        reloginWatch?.cancel()
        // A 404 seen while joining was already answered by the join itself.
        _ = forgottenNode.consume()
        reloginWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reloginCheckInterval)
                guard let self, !Task.isCancelled else { return }
                await self.reloginIfForgotten()
            }
        }
    }

    // Logs the running node back in under a fresh key, in place. Replacing
    // it would not work: a new node started on the same state directory has
    // a profile, so tsnet ignores its key and it waits in NeedsLogin inside
    // tailscale_up for good. Keeping the node also keeps its SOCKS proxy and
    // the shim's tailnet route valid, so nothing else has to be redone.
    private func reloginIfForgotten() async {
        guard let node, shim != nil else { return }
        guard Self.shouldMint(needsLogin: true, lastAttempt: lastRelogin, now: Date()) else {
            return
        }
        var forgotten = forgottenNode.consume()
        if !forgotten {
            forgotten = await Self.needsLogin(node)
        }
        guard forgotten else { return }

        do {
            try await relogin(reason: "headscale forgot this node")
        } catch {
            logger?("tailnet: could not log this node back in: \(error)")
        }
    }

    /// Mints a key and logs the running node in with it, at most once per
    /// cooldown. `lastRelogin` is claimed before the first suspension, so a
    /// watch tick that re-enters while a relogin is in flight skips instead
    /// of spending another key and restarting the backend mid-login.
    private func relogin(reason: String) async throws {
        guard let node, let shim else { throw TailnetError.notJoined }
        guard Self.shouldMint(needsLogin: true, lastAttempt: lastRelogin, now: Date()) else {
            return
        }
        lastRelogin = Date()

        logger?("tailnet: \(reason); minting a key")
        let key = try await shim.mintPreauthKey()
        try await Self.logIn(node: node, key: key)
        logger?("tailnet: logged in again with a new key")
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

/// Forwards TailscaleKit's own lines into the app log, and hands tsnet the
/// descriptor its backend log is written to. `logger: nil` is what left a
/// hung NeedsLogin looking like tsnet had gone silent.
///
/// The two logs are separate: `log(_:)` only gets the Swift wrapper's few
/// lifecycle lines, while control, map-poll and relay messages, including
/// the 404 for a forgotten node, only ever reach `logFileHandle`. Without a
/// descriptor tsnet discards them. Both feed the signal, even when the app
/// has no logger.
private struct TailscaleLogBridge: LogSink, Sendable {
    let emit: (@Sendable (String) -> Void)?
    let forgottenNode: TailnetForgottenNodeSignal

    /// Owned by the node from here on: libtailscale wraps it in a Go file,
    /// which closes it once the node is gone.
    let logFileHandle: Int32?

    func log(_ message: String) {
        forgottenNode.observe(message)
        emit?("tsnet: \(message)")
    }
}

/// Carries tsnet's backend log into the app for as long as the manager lives.
///
/// One pipe serves every node the manager ever starts. Each node gets its
/// own duplicate of the write end, because Go closes the descriptor it was
/// given when that node is collected, and a shared one would then go dead
/// for every later node.
final class TailnetLogPipe: @unchecked Sendable {
    private let pipe = Pipe()
    private let lock = NSLock()
    private var lines = TailnetLogLines()

    /// - Parameter onLine: called with each complete line, off the caller's
    ///   queue. Must not block for long: tsnet's logging waits on this pipe
    ///   once its buffer is full.
    init(onLine: @escaping @Sendable (String) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            let complete = self.lines.feed(data)
            self.lock.unlock()
            complete.forEach(onLine)
        }
    }

    /// A fresh write descriptor for one node, or nil if none can be had. A
    /// node without one runs normally, only blind to being forgotten.
    func writeHandleForNode() -> Int32? {
        let handle = dup(pipe.fileHandleForWriting.fileDescriptor)
        return handle >= 0 ? handle : nil
    }
}

/// Reassembles log lines from pipe reads, which end wherever the OS chooses,
/// often mid-line. A line is only released once its newline has arrived, so
/// nothing is logged in pieces or matched against a fragment. NULs, which
/// Tailscale puts in its structured-line tag, are dropped so the app log
/// stays plain text.
struct TailnetLogLines {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var complete: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline].filter { $0 != 0 }
            complete.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return complete
    }
}

/// Remembers that headscale answered a map poll with "node not found".
///
/// That 404 is how a running node learns that a wiped headscale lost its
/// registration. The node itself retries forever and stays Running. When
/// gitd expires device nodes instead, the node goes to NeedsLogin, which the
/// relogin watch reads from the node's status.
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
