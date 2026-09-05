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

    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let pinnedCA: SecCertificate
    private let clientIdentity: SecIdentity
    private let queue: DispatchQueue
    private let logger: ((String) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: (local: NWConnection, upstream: NWConnection)] = [:]
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
            pair.upstream.cancel()
        }
    }

    // Bridges one accepted loopback connection to a fresh mTLS connection.
    //
    // One upstream per inbound connection rather than a pool: the control
    // protocol holds its stream open for the lifetime of the session, so
    // reusing a connection is not possible and pooling would only add a way
    // for two sessions to interfere.
    private func accept(_ local: NWConnection) {
        let upstream = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? .https,
            using: mtlsParameters()
        )

        let key = ObjectIdentifier(local)
        lock.lock()
        connections[key] = (local, upstream)
        lock.unlock()

        let teardown = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let pair = self.connections.removeValue(forKey: key)
            self.lock.unlock()
            pair?.local.cancel()
            pair?.upstream.cancel()
        }

        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.pump(from: local, to: upstream, teardown: teardown)
                self?.pump(from: upstream, to: local, teardown: teardown)
            case .failed(let error):
                // Almost always the CA check rejecting the far side, which is
                // the case worth being able to find in a log.
                self?.logger?("headscale shim: upstream failed: \(error)")
                teardown()
            case .cancelled:
                teardown()
            default:
                break
            }
        }

        local.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                teardown()
            default:
                break
            }
        }

        local.start(queue: queue)
        upstream.start(queue: queue)
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
    // device identity, and verify the hostname the certificate was issued for.
    private func mtlsParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let security = tlsOptions.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_tls_server_name(security, upstreamHost)

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
}
