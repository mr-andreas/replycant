import Foundation

/// Routes every URLSession that talks to gitd through the tailnet.
///
/// The app has five places that build a session for the server (the libgit2
/// transport, LFS, HLS playback, direct playback, and recovery discovery), and
/// each one constructs its own configuration. Installing the proxy at each site
/// would mean five chances for a new call site to silently bypass the tailnet
/// and fail with a name it cannot resolve, so they all route through here.
///
/// This is deliberately a global. The alternative is threading a node handle
/// through the libgit2 subtransport, which is reached through C callbacks with
/// no place to carry one.
public final class TailnetSessionRouter: @unchecked Sendable {
    public static let shared = TailnetSessionRouter()

    /// Why a session could not be routed.
    public enum RoutingError: LocalizedError, Equatable {
        /// The device belongs to a tailnet whose node is not up yet. Launch
        /// does not wait indefinitely for the join, so requests can arrive in
        /// this window and must be refused rather than dialled directly.
        case notConnectedYet

        public var errorDescription: String? {
            "Not connected to your library's network yet."
        }
    }

    private let lock = NSLock()
    private var node: TailnetNodeProviding?
    private var expectsTailnet = false
    private var currentGeneration: UInt64 = 0

    /// Public so tests can use a private router instead of the shared one,
    /// which suites running in parallel also depend on.
    public init() {}

    /// Reports whether traffic should be going through a tailnet at all.
    ///
    /// True while a join is still pending, so call sites refuse rather than
    /// dial directly. False only for devices with no tailnet configured.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return node != nil || expectsTailnet
    }

    /// Changes whenever routing does. A long-lived session records the
    /// generation it was built under and rebuilds once it differs, which is
    /// how a session created during a background join picks up the node.
    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    /// Marks this device as reached over a tailnet whose node is not up yet.
    ///
    /// Called before a join starts, so requests issued while it runs fail
    /// fast with `RoutingError.notConnectedYet` instead of escaping the
    /// tailnet. Drops any installed node, because the join replaces it.
    public func expectTailnet() {
        lock.lock()
        node = nil
        expectsTailnet = true
        currentGeneration += 1
        lock.unlock()
    }

    /// Installs the node every later session will be proxied through, or
    /// clears routing entirely when the device leaves its tailnet.
    public func use(_ node: TailnetNodeProviding?) {
        lock.lock()
        self.node = node
        expectsTailnet = false
        currentGeneration += 1
        lock.unlock()
    }

    private var currentState: (node: TailnetNodeProviding?, pending: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (node, expectsTailnet)
    }

    /// Applies the tailnet proxy to a configuration, or leaves it untouched
    /// when no tailnet is in use.
    ///
    /// A failure here is not swallowed: dialling directly instead would leak
    /// the request onto whatever network the device happens to be on and, on a
    /// LAN that happens to resolve the name, could reach an unintended host.
    @discardableResult
    public func apply(to configuration: URLSessionConfiguration) async throws -> Bool {
        let state = currentState
        guard let node = state.node else {
            if state.pending {
                throw RoutingError.notConnectedYet
            }
            return false
        }
        try await node.apply(to: configuration)
        return true
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
    /// Returns whether a proxy was installed. While a join is pending this is
    /// false with `isActive` true, which callers already treat as a refusal.
    @discardableResult
    public func applySynchronously(to configuration: URLSessionConfiguration) -> Bool {
        guard let node = currentState.node else {
            return false
        }
        return node.applyCachedProxy(to: configuration)
    }
}
