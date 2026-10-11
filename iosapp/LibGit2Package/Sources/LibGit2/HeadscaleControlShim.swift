import CryptoKit
import Foundation
import Network
import Security

/// Presents the deployment's headscale control plane to Tailscale as a plain
/// HTTP endpoint on loopback.
///
/// TailscaleKit takes a control URL but gives no way to install a private trust
/// root or a client certificate for it, and this deployment's control plane
/// sits behind an mTLS front door signed by a CA that exists only on the user's
/// own server. So the tailnet client talks unencrypted HTTP to this listener,
/// and this listener re-establishes the connection over TLS with the CA pinned
/// and the device's identity presented.
///
/// The plaintext hop never leaves the device: the listener binds to loopback
/// only, and the control protocol itself (Noise) is end-to-end encrypted
/// between the tailnet client and headscale regardless, so the outer TLS is
/// defence in depth and an authorization gate rather than the only protection.
///
/// Traffic is relayed as opaque bytes rather than parsed. Tailscale's control
/// protocol upgrades an HTTP POST into a long-lived bidirectional stream, which
/// no HTTP proxying layer would survive.
public final class HeadscaleControlShim {
    /// Why a shim failed to start or relay, kept specific enough that a pairing
    /// failure can be told apart from a trust failure in a user's logs.
    public enum ShimError: Error, Equatable {
        case notStarted
        case listenerFailed(String)
        case invalidUpstream(String)
        /// hsproxy declined to mint a key, with the HTTP status it gave. A
        /// 403 means this device is not, or is no longer, in `pubkeys/`.
        case keyRefused(Int)
        case malformedKeyResponse
    }

    /// The one request hsproxy answers itself instead of passing to
    /// headscale. Shared with the Go clients through hsproxy's contract.
    static let preauthKeyPath = "/replycant/preauthkey"

    /// What the shim knows about the deployment CA before it connects.
    public enum Trust {
        /// The CA from onboarding, the normal case for a joined device.
        case pinned(SecCertificate)
        /// Only the CA's SHA-256 (DER, hex), as on a phone restoring from a
        /// recovery key. Such a phone cannot fetch the CA anywhere first: the
        /// discovery page is loopback-only and gitd sits behind the tailnet.
        /// hsproxy therefore sends the CA after its leaf, and the one whose
        /// hash matches becomes the anchor.
        case caSHA256(String)
    }

    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let trust: Trust
    private var verifiedCAStorage: SecCertificate?
    private let clientIdentity: SecIdentity
    private let preDialCount: Int
    private let preDialMaxAge: Duration
    private let queue: DispatchQueue
    private let logger: ((String) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: (local: NWConnection, upstream: NWConnection?)] = [:]
    /// Upstreams dialled at start and not yet handed to a loopback client.
    /// Oldest first, which is the order they were opened.
    private var preDialled: [Upstream] = []
    /// Every upstream still open, so a state callback can find its own
    /// record without the connection retaining that record.
    private var upstreams: [ObjectIdentifier: Upstream] = [:]
    private let lock = NSLock()

    /// - Parameters:
    ///   - upstreamHost: hsproxy's hostname. Also the name TLS is verified
    ///     against, so it must be the name the certificate was issued for and
    ///     not an address.
    ///   - trust: the deployment CA, or its hash. The only anchor trusted for
    ///     this connection; the system trust store is not consulted.
    ///   - clientIdentity: the device identity. hsproxy authorizes by public
    ///     key against the deployment's authorized-key list, so this is the
    ///     same identity used for gitd and revocation reaches both at once.
    ///   - preDialCount: how many upstream connections to open as soon as the
    ///     listener is ready, so the relay handshakes overlap the Go node
    ///     starting instead of sitting on the join. Two covers the control
    ///     connections tsnet opens on a launch.
    ///   - preDialMaxAge: how long an unused pre-dialled connection may be
    ///     handed out. Kept under hsproxy's wait for the first request line,
    ///     so a connection that sat idle is not served to a client that
    ///     would then find it already closed.
    public init(
        upstreamHost: String,
        upstreamPort: UInt16,
        trust: Trust,
        clientIdentity: SecIdentity,
        logger: ((String) -> Void)? = nil,
        preDialCount: Int = 2,
        preDialMaxAge: Duration = .seconds(10)
    ) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.trust = trust
        if case .pinned(let ca) = trust {
            self.verifiedCAStorage = ca
        }
        self.clientIdentity = clientIdentity
        self.queue = DispatchQueue(label: "com.replycant.headscale-shim")
        self.logger = logger
        self.preDialCount = preDialCount
        self.preDialMaxAge = preDialMaxAge
    }

    /// The control URL to hand TailscaleKit, valid only after `start()`.
    public private(set) var controlURL: String?

    /// The loopback port the listener bound to. Chosen by the kernel so two
    /// app launches, or an app and a leftover listener, cannot collide.
    public var port: UInt16? {
        listener?.port?.rawValue
    }

    /// Binds the loopback listener and returns once it is ready to accept.
    ///
    /// Waits for readiness rather than returning immediately because the
    /// caller's next move is to hand the URL to Tailscale, which would
    /// otherwise race the bind.
    public func start() async throws {
        guard !upstreamHost.isEmpty else {
            throw ShimError.invalidUpstream("headscale host is empty")
        }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw ShimError.listenerFailed(String(describing: error))
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    if let boundPort = listener.port?.rawValue {
                        self?.controlURL = "http://127.0.0.1:\(boundPort)"
                        // Dial before resuming so the handshakes are in
                        // flight by the time the caller starts the node.
                        self?.beginPreDials()
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ShimError.listenerFailed("listener bound without a port"))
                    }
                case .failed(let error):
                    // After ready, this is the listener iOS reclaimed while
                    // the app was suspended. Nothing is waiting on start()
                    // anymore, so the log is the only record.
                    guard !resumed else {
                        self?.logger?("headscale shim: listener failed: \(error)")
                        return
                    }
                    resumed = true
                    continuation.resume(throwing: ShimError.listenerFailed(String(describing: error)))
                case .cancelled:
                    guard resumed else { break }
                    self?.logger?("headscale shim: listener cancelled")
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Tears down the listener and every relay through it.
    ///
    /// Called when the tailnet goes down. Leaving relays open would keep
    /// connections alive against a control plane the app has stopped using,
    /// and on iOS would hold sockets across a suspend the OS wants to reclaim.
    public func stop() {
        listener?.cancel()
        listener = nil
        controlURL = nil

        lock.lock()
        let open = connections
        connections.removeAll()
        let pending = preDialled
        preDialled.removeAll()
        upstreams.removeAll()
        lock.unlock()

        for (_, pair) in open {
            pair.upstream?.stateUpdateHandler = nil
            pair.local.cancel()
            pair.upstream?.cancel()
        }
        for upstream in pending {
            upstream.connection.stateUpdateHandler = nil
            upstream.connection.cancel()
        }
    }

    /// Asks hsproxy for a fresh single-use key for this device's node.
    ///
    /// headscale's state is a cache of the deployment's `pubkeys/`, so it can
    /// be wiped at any time, and a device being authorized is what entitles
    /// it to a key. The request rides this shim's own loopback listener, so
    /// it gets the pinned CA and the device certificate for free, and hsproxy
    /// can check the certificate before minting.
    ///
    /// Throws `keyRefused` if hsproxy declines, which is what a device that
    /// was removed from `pubkeys/` sees; that is not worth retrying soon.
    public func mintPreauthKey() async throws -> String {
        guard let controlURL, let url = URL(string: controlURL + Self.preauthKeyPath) else {
            throw ShimError.notStarted
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return try Self.decodePreauthKey(data: data, response: response)
    }

    /// Reads hsproxy's answer to a key request.
    ///
    /// Strict about an empty key because a node handed one would sit waiting
    /// for an interactive login that a phone can never complete.
    static func decodePreauthKey(data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else {
            throw ShimError.malformedKeyResponse
        }
        guard http.statusCode == 200 else {
            throw ShimError.keyRefused(http.statusCode)
        }
        struct Wire: Decodable {
            let preauth_key: String?
        }
        let key = (try? JSONDecoder().decode(Wire.self, from: data))?
            .preauth_key?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            throw ShimError.malformedKeyResponse
        }
        return key
    }

    /// Opens the launch connections before tsnet asks for them.
    ///
    /// tsnet dials twice during a cold start, and each dial otherwise waits
    /// out its own relay handshake after the Go node has already started.
    /// Opening them here overlaps those handshakes with that startup. Later
    /// connections are not replaced: only the launch pays this cost.
    private func beginPreDials() {
        guard preDialCount > 0 else { return }
        for _ in 0..<preDialCount {
            _ = dialUpstream(reserve: true)
        }
        let delay = Self.seconds(preDialMaxAge)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.expireUnusedPreDials()
        }
    }

    /// Drops pre-dialled connections hsproxy may already have given up on.
    ///
    /// hsproxy only waits so long for the first request line. A connection
    /// opened at launch and never used would be closed by then, and handing
    /// it to tsnet would fail the join.
    private func expireUnusedPreDials() {
        lock.lock()
        let unused = preDialled
        preDialled.removeAll()
        for upstream in unused {
            upstreams.removeValue(forKey: ObjectIdentifier(upstream.connection))
        }
        lock.unlock()
        for upstream in unused {
            upstream.connection.stateUpdateHandler = nil
            upstream.connection.cancel()
        }
    }

    /// Hands a loopback client the oldest pre-dialled upstream still young
    /// enough to use, or dials a new one when none is.
    ///
    /// One upstream per inbound connection: the control protocol holds its
    /// stream open for the session, so a used connection cannot be shared.
    private func accept(_ local: NWConnection) {
        let key = ObjectIdentifier(local)
        lock.lock()
        connections[key] = (local, nil)
        lock.unlock()

        local.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.teardown(key)
            default:
                break
            }
        }
        local.start(queue: queue)
        let upstream = takePreDialled() ?? dialUpstream(reserve: false)
        bind(local, key: key, to: upstream)
    }

    /// Takes the oldest pre-dialled upstream younger than `preDialMaxAge`.
    ///
    /// Older ones are cancelled rather than handed out: the far side may
    /// have closed them, and a client put on a dead connection fails.
    private func takePreDialled() -> Upstream? {
        let limit = Self.seconds(preDialMaxAge)
        let now = Date()
        lock.lock()
        var chosen: Upstream?
        var discarded: [Upstream] = []
        var kept: [Upstream] = []
        for upstream in preDialled {
            if chosen != nil {
                kept.append(upstream)
            } else if now.timeIntervalSince(upstream.dialledAt) < limit {
                chosen = upstream
            } else {
                discarded.append(upstream)
            }
        }
        preDialled = kept
        for upstream in discarded {
            upstreams.removeValue(forKey: ObjectIdentifier(upstream.connection))
        }
        lock.unlock()
        for upstream in discarded {
            upstream.connection.stateUpdateHandler = nil
            upstream.connection.cancel()
        }
        return chosen
    }

    /// Opens one mTLS connection to hsproxy.
    ///
    /// `reserve` parks it for the next loopback client. The state handler is
    /// installed before the connection starts, on this shim's queue, so a
    /// ready connection and the client that binds it cannot miss each other.
    private func dialUpstream(reserve: Bool) -> Upstream {
        let connection = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? .https,
            using: mtlsParameters(serverName: upstreamHost)
        )
        let upstream = Upstream(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state, of: upstream)
        }
        lock.lock()
        upstreams[ObjectIdentifier(connection)] = upstream
        if reserve {
            preDialled.append(upstream)
        }
        lock.unlock()
        connection.start(queue: queue)
        return upstream
    }

    /// Attaches a loopback client to an upstream, relaying immediately when
    /// the handshake already finished.
    private func bind(_ local: NWConnection, key: ObjectIdentifier, to upstream: Upstream) {
        lock.lock()
        let stillOpen = connections[key] != nil
        if stillOpen {
            connections[key] = (local, upstream.connection)
        }
        lock.unlock()
        guard stillOpen else {
            forget(upstream)
            return
        }
        upstream.bound = (local, key)
        if upstream.isReady {
            startPumps(upstream)
        }
    }

    /// Relays once both halves exist. Ready can arrive before the client
    /// does, or after, and either order has to start the copy exactly once.
    private func startPumps(_ upstream: Upstream) {
        guard !upstream.pumpsStarted, let bound = upstream.bound else { return }
        upstream.pumpsStarted = true
        let key = bound.key
        pump(from: bound.local, to: upstream.connection, teardown: { [weak self] in
            self?.teardown(key)
        })
        pump(from: upstream.connection, to: bound.local, teardown: { [weak self] in
            self?.teardown(key)
        })
    }

    /// Reacts to an upstream's state. An unused failure is dropped from the
    /// pre-dial list; a bound one takes its loopback client down with it.
    private func handle(_ state: NWConnection.State, of upstream: Upstream) {
        switch state {
        case .ready:
            if !upstream.didLogReady {
                upstream.didLogReady = true
                logger?("headscale shim: connected to \(upstreamHost):\(upstreamPort)")
            }
            upstream.isReady = true
            startPumps(upstream)
        case .failed(let error):
            // Almost always the CA check rejecting the far side, which is
            // the case worth being able to find in a log.
            logger?("headscale shim: upstream failed: \(error)")
            if let key = upstream.bound?.key {
                teardown(key)
            } else {
                forget(upstream)
            }
        case .cancelled:
            if let key = upstream.bound?.key {
                teardown(key)
            } else {
                forget(upstream)
            }
        case .waiting(let error):
            // The only sign that the relay is stuck instead of moving
            // bytes. Logged once so a long wait is visible without a
            // line per state update.
            guard !upstream.reportedWaiting else { return }
            upstream.reportedWaiting = true
            logger?("headscale shim: route to \(upstreamHost):\(upstreamPort) waiting: \(error)")
        default:
            break
        }
    }

    /// Forgets an upstream that never served a client, and closes it.
    private func forget(_ upstream: Upstream) {
        lock.lock()
        preDialled.removeAll { $0 === upstream }
        upstreams.removeValue(forKey: ObjectIdentifier(upstream.connection))
        lock.unlock()
        upstream.connection.stateUpdateHandler = nil
        upstream.connection.cancel()
    }

    /// Closes both halves of one relayed connection and forgets it.
    private func teardown(_ key: ObjectIdentifier) {
        lock.lock()
        let pair = connections.removeValue(forKey: key)
        let upstream = pair?.upstream.flatMap { upstreams.removeValue(forKey: ObjectIdentifier($0)) }
        lock.unlock()
        upstream?.connection.stateUpdateHandler = nil
        pair?.local.cancel()
        pair?.upstream?.cancel()
    }

    /// Seconds in a duration, for the queue's timeout API.
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    // Copies bytes one direction until either side closes.
    private func pump(from source: NWConnection, to destination: NWConnection, teardown: @escaping () -> Void) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error {
                _ = error
                teardown()
                return
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        teardown()
                        return
                    }
                    self.pump(from: source, to: destination, teardown: teardown)
                })
                return
            }
            if isComplete {
                teardown()
                return
            }
            self.pump(from: source, to: destination, teardown: teardown)
        }
    }

    // Builds the upstream TLS options: pin the deployment CA, present the
    // device identity, and name the host the certificate was issued for.
    private func mtlsParameters(serverName: String) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let security = tlsOptions.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_tls_server_name(security, serverName)

        if let identity = sec_identity_create(clientIdentity) {
            sec_protocol_options_set_local_identity(security, identity)
        }

        let configuredTrust = self.trust
        sec_protocol_options_set_verify_block(
            security,
            { [weak self] _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                switch configuredTrust {
                case .pinned(let ca):
                    complete(Self.evaluate(trust: trust, pinnedCA: ca))
                case .caSHA256(let hash):
                    guard let ca = Self.evaluate(trust: trust, caSHA256: hash) else {
                        complete(false)
                        return
                    }
                    self?.recordVerifiedCA(ca)
                    complete(true)
                }
            },
            queue
        )

        return NWParameters(tls: tlsOptions)
    }

    /// Decides whether a presented chain belongs to this deployment.
    ///
    /// Exposed for tests, which is the only way to cover the trust decision
    /// without standing up a real TLS server: the verify block itself is
    /// invoked by Network framework and cannot be called directly.
    ///
    /// The onboarded CA replaces the system trust store rather than being added
    /// to it. A publicly trusted certificate for the same hostname must not be
    /// accepted, because the hostname is a subdomain of a shared tunnel domain
    /// whose operator could otherwise obtain one.
    ///
    /// Deliberately a basic X.509 policy, not `SecPolicyCreateSSL`. The SSL
    /// policy enforces Apple's 398-day maximum certificate lifetime even for a
    /// programmatically pinned anchor, and a deployment's CA issues long-lived
    /// leaves precisely so a self-hosted server never breaks on an unattended
    /// expiry. Using it would reject every real deployment.
    ///
    /// What that gives up is hostname matching, which buys nothing here: the
    /// deployment CA signs only the two server certificates on the user's own
    /// host, and device identities are self-signed. Presenting a
    /// wrong-hostname certificate from this CA therefore already requires the
    /// private key of a certificate on that host. iOS offers no way to read
    /// subject alternative names, so checking the name would mean shipping an
    /// X.509 parser for a threat that does not exist.
    public static func evaluate(trust: SecTrust, pinnedCA: SecCertificate) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess else {
            return false
        }
        guard SecTrustSetAnchorCertificates(trust, [pinnedCA] as CFArray) == errSecSuccess else {
            return false
        }
        guard SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// Finds the CA a recovery key names in the presented chain and verifies
    /// the leaf against it, returning that CA so the app can pin it from then
    /// on. The hash is what makes this safe: anyone can send a CA in their
    /// chain, but only the deployment's has this digest.
    public static func evaluate(trust: SecTrust, caSHA256: String) -> SecCertificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let ca = chain.first(where: {
                  sha256Hex(SecCertificateCopyData($0) as Data)
                      .caseInsensitiveCompare(caSHA256) == .orderedSame
              }) else {
            return nil
        }
        return evaluate(trust: trust, pinnedCA: ca) ? ca : nil
    }

    /// The CA connections are anchored to: the pinned one, or once a
    /// handshake has succeeded, the one picked from hsproxy's chain by hash.
    public var verifiedCA: SecCertificate? {
        lock.lock()
        defer { lock.unlock() }
        return verifiedCAStorage
    }

    private func recordVerifiedCA(_ ca: SecCertificate) {
        lock.lock()
        verifiedCAStorage = ca
        lock.unlock()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An upstream connection to hsproxy, dialled ahead of the client that
    /// will use it or when that client arrives.
    ///
    /// Kept separate from the loopback connection so the relay handshake can
    /// finish while the tailnet node is still starting. Fields other than the
    /// connection are touched only on the shim's serial queue.
    private final class Upstream {
        let connection: NWConnection
        let dialledAt = Date()
        var isReady = false
        var pumpsStarted = false
        var didLogReady = false
        var reportedWaiting = false
        var bound: (local: NWConnection, key: ObjectIdentifier)?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }
}
