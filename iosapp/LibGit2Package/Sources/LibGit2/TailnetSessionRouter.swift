import Foundation

/// Routes every URLSession that talks to gitd through the tailnet.
///
/// The app has several places that build a session for the server (the
/// libgit2 transport, LFS, HLS playback, direct playback, and pairing), and
/// each one constructs its own configuration. Installing the proxy at each site
/// would mean one more chance per call site to silently bypass the tailnet and
/// fail with a name it cannot resolve, so they all route through here.
///
/// This is deliberately a global. The alternative is threading a node handle
/// through the libgit2 subtransport, which is reached through C callbacks with
/// no place to carry one.
public final class TailnetSessionRouter: @unchecked Sendable {
    public static let shared = TailnetSessionRouter()

    /// Why a session could not be routed.
    public enum RoutingError: LocalizedError, Equatable {
        /// The device's node is not up. gitd is reachable only over the
        /// tailnet, and launch does not wait for the join, so requests
        /// issued before it finishes are refused rather than dialled
        /// directly.
        case notConnectedYet

        public var errorDescription: String? {
            "Not connected to your library's network yet."
        }
    }

    private let lock = NSLock()
    private var node: TailnetNodeProviding?
    private var currentGeneration: UInt64 = 0

    /// Public so tests can use a private router instead of the shared one,
    /// which suites running in parallel also depend on.
    public init() {}

    /// Changes whenever routing does. A long-lived session records the
    /// generation it was built under and rebuilds once it differs, which is
    /// how a session created during a background join picks up the node.
    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    /// Installs the node every later session will be proxied through, or
    /// clears it while a join is replacing it or the device leaves its
    /// tailnet. Requests fail fast with `RoutingError.notConnectedYet` until
    /// a node is installed again.
    public func use(_ node: TailnetNodeProviding?) {
        lock.lock()
        self.node = node
        currentGeneration += 1
        lock.unlock()
    }

    private var currentNode: TailnetNodeProviding? {
        lock.lock()
        defer { lock.unlock() }
        return node
    }

    /// Applies the tailnet proxy to a configuration.
    ///
    /// A failure here is not swallowed: dialling directly instead would leak
    /// the request onto whatever network the device happens to be on, where
    /// a resolver that answers for gitd's name could reach an unintended host.
    public func apply(to configuration: URLSessionConfiguration) async throws {
        guard let node = currentNode else {
            throw RoutingError.notConnectedYet
        }
        try await node.apply(to: configuration)
    }

    /// Builds a session configuration already routed through the tailnet.
    ///
    /// The async entry point for call sites that can await. Synchronous C
    /// callback paths use `applySynchronously` instead.
    public func configuration(basedOn base: URLSessionConfiguration) async throws -> URLSessionConfiguration {
        guard let copy = base.copy() as? URLSessionConfiguration else {
            return base
        }
        try await apply(to: copy)
        return copy
    }

    /// Applies the proxy from a context that cannot await.
    ///
    /// libgit2 drives its subtransport through synchronous C callbacks, so the
    /// session there has to be built without an await. The SOCKS settings were
    /// captured when the node joined, so this is a dictionary copy rather than
    /// a hop onto the node actor — waiting on that hop from a User-initiated
    /// or User-interactive thread is a priority inversion.
    ///
    /// Returns whether a proxy was installed. Callers refuse the request when
    /// it was not, for the same reason `apply` throws.
    @discardableResult
    public func applySynchronously(to configuration: URLSessionConfiguration) -> Bool {
        guard let node = currentNode else {
            return false
        }
        return node.applyCachedProxy(to: configuration)
    }
}
