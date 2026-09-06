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
    }

    /// Which way a control connection reached the deployment.
    ///
    /// Worth distinguishing because the two have different consequences for
    /// the user: `relay` means they still depend on replycant's hosted service
    /// to stay connected, `tailnet` means they no longer do.
    public enum Route: String, Sendable {
        case tailnet
        case relay
    }

    /// The in-tailnet path to the control plane, installed once the node is up.
    ///
    /// It cannot be a constructor argument because it does not exist yet when
    /// the shim is built: the node needs the shim's control URL in order to
    /// come up at all, so the first control session necessarily predates any
    /// tailnet route.
    public struct TailnetRoute: Sendable {
        /// gitd's MagicDNS name, which is both the dial target and the name
        /// hsproxy's certificate carries on this path.
        public let host: String
        public let port: UInt16

        /// The node's SOCKS5 loopback proxy. Everything on this path has to go
        /// through it: a tailnet address is only routable through the node's
        /// userspace WireGuard stack, and a MagicDNS name is only resolvable
        /// by the node's own resolver.
        public let socksProxy: NWEndpoint
        public let socksUsername: String
        public let socksPassword: String

        public init(
            host: String,
            port: UInt16,
            socksProxy: NWEndpoint,
            socksUsername: String,
            socksPassword: String
        ) {
            self.host = host
            self.port = port
            self.socksProxy = socksProxy
            self.socksUsername = socksUsername
            self.socksPassword = socksPassword
        }
    }

    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let pinnedCA: SecCertificate
    private let clientIdentity: SecIdentity
    private let queue: DispatchQueue
    private let logger: ((String) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: (local: NWConnection, upstream: NWConnection?)] = [:]
    private var tailnetRoute: TailnetRoute?
    private var lastRouteUsed: Route?
    private let lock = NSLock()

    /// - Parameters:
    ///   - upstreamHost: hsproxy's hostname. Also the name TLS is verified
    ///     against, so it must be the name the certificate was issued for and
    ///     not an address.
    ///   - pinnedCA: the deployment CA from onboarding. The only anchor trusted
    ///     for this connection; the system trust store is not consulted.
    ///   - clientIdentity: the device identity. hsproxy authorizes by public
    ///     key against the deployment's authorized-key list, so this is the
    ///     same identity used for gitd and revocation reaches both at once.
    public init(
        upstreamHost: String,
        upstreamPort: UInt16,
        pinnedCA: SecCertificate,
        clientIdentity: SecIdentity,
        logger: ((String) -> Void)? = nil
    ) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.pinnedCA = pinnedCA
        self.clientIdentity = clientIdentity
        self.queue = DispatchQueue(label: "com.replycant.headscale-shim")
        self.logger = logger
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
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ShimError.listenerFailed("listener bound without a port"))
                    }
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: ShimError.listenerFailed(String(describing: error)))
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
        lock.unlock()

        for (_, pair) in open {
            pair.local.cancel()
            pair.upstream?.cancel()
        }
    }

    /// Installs the in-tailnet path to the control plane.
    ///
    /// Safe to call while serving, and expected to be: the caller installs it
    /// as soon as the node is up, which is always after the shim has already
    /// carried at least one control session through the relay.
    public func setTailnetRoute(_ route: TailnetRoute) throws {
        guard !route.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ShimError.invalidUpstream("tailnet route host is empty")
        }
        lock.lock()
        tailnetRoute = route
        lock.unlock()
    }

    /// Which path the most recent connection took, or nil before the first one.
    ///
    /// Surfaced so the app can tell the user whether they still depend on the
    /// hosted relay to stay connected.
    public var lastRoute: Route? {
        lock.lock()
        defer { lock.unlock() }
        return lastRouteUsed
    }

    // Bridges one accepted loopback connection to a fresh mTLS connection.
    //
    // One upstream per inbound connection rather than a pool: the control
    // protocol holds its stream open for the lifetime of the session, so
    // reusing a connection is not possible and pooling would only add a way
    // for two sessions to interfere.
    private func accept(_ local: NWConnection) {
        let key = ObjectIdentifier(local)
        lock.lock()
        connections[key] = (local, nil)
        let route = tailnetRoute
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

        // The tailnet is preferred but never assumed: it depends on the node
        // being up and the server being online, and a device that cannot use
        // it must still be able to reach the control plane rather than being
        // stranded.
        var attempts: [Attempt] = []
        if let route {
            attempts.append(Attempt(
                route: .tailnet,
                host: route.host,
                port: route.port,
                parameters: mtlsParameters(serverName: route.host, tailnet: route),
                // Short, because a node that is down makes this hang rather
                // than fail, and the cost is paid on every control connection.
                timeout: 2
            ))
        }
        attempts.append(Attempt(
            route: .relay,
            host: upstreamHost,
            port: upstreamPort,
            parameters: mtlsParameters(serverName: upstreamHost, tailnet: nil),
            timeout: nil
        ))

        connect(local: local, key: key, attempts: attempts)
    }

    // One way to reach the control plane, tried in order.
    private struct Attempt {
        let route: Route
        let host: String
        let port: UInt16
        let parameters: NWParameters

        // nil means wait as long as the network stack does. Only the tailnet
        // attempt is time-boxed, because only it has a fallback.
        let timeout: TimeInterval?
    }

    // Tries each way to reach the control plane until one connects.
    private func connect(local: NWConnection, key: ObjectIdentifier, attempts: [Attempt]) {
        guard let attempt = attempts.first else {
            // Every path failed. Closing the local side turns this into a
            // prompt error for the Tailscale client, which retries with
            // backoff, rather than a stall.
            teardown(key)
            return
        }

        let upstream = NWConnection(
            host: NWEndpoint.Host(attempt.host),
            port: NWEndpoint.Port(rawValue: attempt.port) ?? .https,
            using: attempt.parameters
        )

        lock.lock()
        // Only replace the upstream if this connection is still live; a
        // teardown between attempts must not resurrect it.
        let stillOpen = connections[key] != nil
        if stillOpen {
            connections[key] = (local, upstream)
        }
        lock.unlock()
        guard stillOpen else {
            upstream.cancel()
            return
        }

        // Both flags are only touched on the shim's serial queue, which every
        // state callback and the timer below run on.
        var settled = false
        var advanced = false
        let advance: (String) -> Void = { [weak self] reason in
            guard let self, !settled, !advanced else { return }
            advanced = true
            self.logger?("headscale shim: \(attempt.route.rawValue) route to "
                + "\(attempt.host):\(attempt.port) unavailable: \(reason)")
            upstream.cancel()
            self.connect(local: local, key: key, attempts: Array(attempts.dropFirst()))
        }

        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                settled = true
                self.lock.lock()
                self.lastRouteUsed = attempt.route
                self.lock.unlock()
                self.pump(from: local, to: upstream, teardown: { self.teardown(key) })
                self.pump(from: upstream, to: local, teardown: { self.teardown(key) })
            case .failed(let error):
                if settled {
                    // Almost always the CA check rejecting the far side, which
                    // is the case worth being able to find in a log.
                    self.logger?("headscale shim: upstream failed: \(error)")
                    self.teardown(key)
                } else {
                    advance(String(describing: error))
                }
            case .cancelled:
                if !advanced {
                    self.teardown(key)
                }
            default:
                break
            }
        }

        if let timeout = attempt.timeout {
            queue.asyncAfter(deadline: .now() + timeout) {
                advance("timed out after \(timeout)s")
            }
        }

        upstream.start(queue: queue)
    }

    // Closes both halves of one relayed connection and forgets it.
    private func teardown(_ key: ObjectIdentifier) {
        lock.lock()
        let pair = connections.removeValue(forKey: key)
        lock.unlock()
        pair?.local.cancel()
        pair?.upstream?.cancel()
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
    //
    // Both paths end at the same hsproxy and use the same anchor and identity;
    // only the name differs, because hsproxy's certificate carries the tunnel
    // hostname and the tailnet name as separate SANs.
    private func mtlsParameters(serverName: String, tailnet: TailnetRoute?) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let security = tlsOptions.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_tls_server_name(security, serverName)

        if let identity = sec_identity_create(clientIdentity) {
            sec_protocol_options_set_local_identity(security, identity)
        }

        let pinnedCA = self.pinnedCA
        sec_protocol_options_set_verify_block(
            security,
            { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                complete(Self.evaluate(trust: trust, pinnedCA: pinnedCA))
            },
            queue
        )

        let parameters = NWParameters(tls: tlsOptions)
        if let tailnet {
            // The node's SOCKS5 proxy is the only way into the tailnet from
            // the host stack, and it is attached through a private privacy
            // context so it applies to this connection alone rather than to
            // everything else the app does.
            var proxy = ProxyConfiguration(socksv5Proxy: tailnet.socksProxy)
            proxy.applyCredential(username: tailnet.socksUsername, password: tailnet.socksPassword)

            let context = NWParameters.PrivacyContext(description: "replycant-tailnet-control")
            context.proxyConfigurations = [proxy]
            parameters.setPrivacyContext(context)
        }
        return parameters
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
}
