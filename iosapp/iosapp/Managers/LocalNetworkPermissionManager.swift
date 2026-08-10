import Foundation
import Network
import Darwin

// Triggers iOS local-network privacy prompts ahead of onboarding network
// operations so first push/clone attempts are not blocked unexpectedly.
final class LocalNetworkPermissionManager {
    static let shared = LocalNetworkPermissionManager()

    private init() {}

    // Requests local-network permission only when QR-provided endpoints target
    // LAN hosts that iOS may gate behind the privacy prompt.
    func requestPermissionIfNeeded(gitServerURL: String, lfsServerURL: String?) async throws {
        try await requestPermissionIfNeeded(endpointURLs: [gitServerURL, lfsServerURL].compactMap { $0 })
    }

    // Requests local-network permission only when at least one endpoint URL points at a LAN host.
    func requestPermissionIfNeeded(endpointURLs: [String]) async throws {
        guard let endpoint = Self.localNetworkEndpoint(endpointURLs: endpointURLs) else {
            return
        }
        try await requestPermissionPreflight(host: endpoint.host, port: endpoint.port)
    }

    // Classifies onboarding endpoints so only LAN-like hosts trigger local
    // network preflight behavior.
    static func shouldRequestPermission(gitServerURL: String, lfsServerURL: String?) -> Bool {
        let candidates = [gitServerURL, lfsServerURL].compactMap { $0 }
        for candidate in candidates {
            guard let host = URL(string: candidate)?.host else {
                continue
            }
            if isLocalNetworkHost(host) {
                return true
            }
        }
        return false
    }

    // Selects the best LAN endpoint to probe so onboarding can verify local
    // network access against the same target family used by clone/sync traffic.
    static func localNetworkEndpoint(gitServerURL: String, lfsServerURL: String?) -> (host: String, port: UInt16)? {
        localNetworkEndpoint(endpointURLs: [gitServerURL, lfsServerURL].compactMap { $0 })
    }

    // Selects the first LAN endpoint from an ordered URL list so callers can prioritize discovery or git hosts.
    static func localNetworkEndpoint(endpointURLs: [String]) -> (host: String, port: UInt16)? {
        for endpointURL in endpointURLs {
            if let endpoint = endpointCandidate(from: endpointURL) {
                return endpoint
            }
        }
        return nil
    }

    // Opens a direct LAN TCP connection so onboarding waits for local-network
    // permission resolution before issuing clone traffic.
    private func requestPermissionPreflight(host: String, port: UInt16) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "LocalNetworkPermissionManager.connection")
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? .https,
                using: params
            )
            let preflightState = ConnectionPreflightState(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    preflightState.finish(.success(()))
                case .failed(let error), .waiting(let error):
                    if Self.isPermissionDeniedError(error) {
                        preflightState.finish(.failure(LocalNetworkPermissionError.denied))
                    } else {
                        // Non-permission networking errors should not block
                        // onboarding; the real request path can report those.
                        preflightState.finish(.success(()))
                    }
                case .cancelled:
                    preflightState.finish(.success(()))
                case .setup, .preparing:
                    break
                @unknown default:
                    preflightState.finish(.success(()))
                }
            }

            queue.asyncAfter(deadline: .now() + 30) {
                preflightState.finish(.success(()))
            }

            connection.start(queue: queue)
        }
    }

    // Detects explicit local-network privacy denials from Network.framework
    // so onboarding can show an actionable user-facing error.
    private static func isPermissionDeniedError(_ error: NWError) -> Bool {
        let description = String(describing: error).lowercased()
        if description.contains("policydenied") || description.contains("policy denied") {
            return true
        }
        if case .posix(let code) = error, code == .EPERM || code == .EACCES {
            return true
        }
        return false
    }

    // Identifies host patterns that represent LAN targets subject to iOS local
    // network privacy prompts.
    private static func isLocalNetworkHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        if normalizedHost == "localhost" {
            return false
        }
        if normalizedHost.hasSuffix(".local") {
            return true
        }
        if isPrivateIPv4(normalizedHost) || isLocalIPv6(normalizedHost) {
            return true
        }
        if !normalizedHost.contains(".") {
            return true
        }
        return false
    }

    // Detects RFC1918 and link-local IPv4 ranges that represent private LAN
    // destinations.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".")
        guard components.count == 4 else { return false }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        let first = octets[0]
        let second = octets[1]
        if first == 10 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 169 && second == 254 { return true }
        return false
    }

    // Detects unique-local and link-local IPv6 ranges used on local networks.
    private static func isLocalIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        let firstByte = address.__u6_addr.__u6_addr8.0
        let secondByte = address.__u6_addr.__u6_addr8.1
        if (firstByte & 0xfe) == 0xfc {
            return true
        }
        if firstByte == 0xfe && (secondByte & 0xc0) == 0x80 {
            return true
        }
        return false
    }

    // Parses URL candidates into concrete LAN endpoints so permission probes
    // target the right host and port for onboarding server settings.
    private static func endpointCandidate(from urlString: String) -> (host: String, port: UInt16)? {
        guard let url = URL(string: urlString), let host = url.host else {
            return nil
        }
        guard isLocalNetworkHost(host) else {
            return nil
        }
        let scheme = url.scheme?.lowercased()
        let rawPort = url.port ?? defaultPort(for: scheme)
        guard (1...65535).contains(rawPort) else {
            return nil
        }
        let port = UInt16(rawPort)
        return (host: host, port: port)
    }

    // Uses protocol defaults when URLs omit explicit ports so permission probes
    // remain aligned with expected endpoint transport.
    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return 443
        }
    }
}

// Owns one connection preflight lifecycle so asynchronous callbacks can finish
// exactly once and safely tear down socket resources.
private final class ConnectionPreflightState: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Void, Error>
    private var hasFinished = false

    // Captures connection + continuation ownership to centralize single-finish
    // semantics for all connection callbacks.
    init(connection: NWConnection, continuation: CheckedContinuation<Void, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    // Finalizes the preflight exactly once and releases connection resources.
    func finish(_ result: Result<Void, Error>) {
        guard !hasFinished else { return }
        hasFinished = true
        connection.cancel()
        continuation.resume(with: result)
    }
}

// Surfaces local-network prompt denial as an actionable onboarding error.
enum LocalNetworkPermissionError: LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Allow Local Network access to connect to your Replycant server."
        }
    }
}
