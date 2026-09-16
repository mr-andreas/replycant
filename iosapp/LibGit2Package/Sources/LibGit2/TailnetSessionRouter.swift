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

    private let lock = NSLock()
    private var node: TailnetNodeProviding?

    private init() {}

    /// Reports whether traffic should be going through a tailnet at all.
    ///
    /// False for LAN deployments, which keep dialling the server directly.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return node != nil
    }

    /// Installs the node every later session will be proxied through.
    ///
    /// Sessions created before this are not retroactively proxied, which is why
    /// callers must join the tailnet before issuing their first request.
    public func use(_ node: TailnetNodeProviding?) {
        lock.lock()
        self.node = node
        lock.unlock()
    }

    private var currentNode: TailnetNodeProviding? {
        lock.lock()
        defer { lock.unlock() }
        return node
    }

    /// Applies the tailnet proxy to a configuration, or leaves it untouched
    /// when no tailnet is in use.
    ///
    /// A failure here is not swallowed: dialling directly instead would leak
    /// the request onto whatever network the device happens to be on and, on a
    /// LAN that happens to resolve the name, could reach an unintended host.
    @discardableResult
    public func apply(to configuration: URLSessionConfiguration) async throws -> Bool {
        guard let node = currentNode else {
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
    /// Returns whether a proxy was installed, so the caller can log a bypass
    /// rather than discovering it as an unresolvable hostname.
    @discardableResult
    public func applySynchronously(to configuration: URLSessionConfiguration) -> Bool {
        guard let node = currentNode else {
            return false
        }
        return node.applyCachedProxy(to: configuration)
    }
}
