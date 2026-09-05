import Foundation
import Testing
import LibGit2

/// Stands in for a running tailnet node.
///
/// A real node needs a userspace WireGuard stack and a reachable control
/// plane, neither of which a unit test can provide, so the router is tested
/// against the one thing it actually depends on: something that can mutate a
/// session configuration or refuse to.
private final class FakeNode: TailnetNodeProviding, @unchecked Sendable {
    let proxyHost: String
    let shouldFail: Bool
    private(set) var applyCount = 0
    private(set) var shutDownCount = 0

    init(proxyHost: String = "127.0.0.1", shouldFail: Bool = false) {
        self.proxyHost = proxyHost
        self.shouldFail = shouldFail
    }

    func apply(to configuration: URLSessionConfiguration) async throws {
        applyCount += 1
        if shouldFail {
            throw TailnetManager.TailnetError.notJoined
        }
        configuration.connectionProxyDictionary = ["stubProxyHost": proxyHost]
    }

    func addresses() async throws -> (ip4: String?, ip6: String?) {
        ("100.64.0.7", nil)
    }

    func shutDown() async {
        shutDownCount += 1
    }
}

@Suite(.serialized)
struct TailnetSessionRouterTests {
    /// The router is a process-wide singleton because libgit2 reaches it
    /// through C callbacks with nowhere to carry a handle. Tests therefore have
    /// to put it back, or one test's node leaks into the next.
    private func withRouter(_ node: TailnetNodeProviding?, _ body: () async throws -> Void) async rethrows {
        TailnetSessionRouter.shared.use(node)
        defer { TailnetSessionRouter.shared.use(nil) }
        try await body()
    }

    // LAN deployments never join a tailnet, and their sessions must be left
    // exactly as the call site built them.
    @Test func inactiveWithoutANode() async throws {
        try await withRouter(nil) {
            #expect(TailnetSessionRouter.shared.isActive == false)

            let configuration = URLSessionConfiguration.ephemeral
            let applied = try await TailnetSessionRouter.shared.apply(to: configuration)

            #expect(applied == false)
            #expect(configuration.connectionProxyDictionary == nil)
        }
    }

    @Test func activeOnceANodeIsInstalled() async throws {
        try await withRouter(FakeNode()) {
            #expect(TailnetSessionRouter.shared.isActive == true)
        }
    }

    // The point of the router: a session built anywhere in the app comes back
    // pointed at the node's proxy.
    @Test func appliesTheProxyToAConfiguration() async throws {
        let node = FakeNode(proxyHost: "127.0.0.1")
        try await withRouter(node) {
            let configuration = URLSessionConfiguration.ephemeral
            let applied = try await TailnetSessionRouter.shared.apply(to: configuration)

            #expect(applied == true)
            #expect(node.applyCount == 1)
            #expect(configuration.connectionProxyDictionary?["stubProxyHost"] as? String == "127.0.0.1")
        }
    }

    // Dialling directly on failure would leak the request onto whatever
    // network the device is on, and on a LAN that resolves the name could
    // reach a host the user never authorized.
    @Test func propagatesAFailureInsteadOfDiallingDirectly() async throws {
        let node = FakeNode(shouldFail: true)
        TailnetSessionRouter.shared.use(node)
        defer { TailnetSessionRouter.shared.use(nil) }

        await #expect(throws: TailnetManager.TailnetError.notJoined) {
            _ = try await TailnetSessionRouter.shared.apply(to: URLSessionConfiguration.ephemeral)
        }
    }

    // libgit2 drives its subtransport through synchronous C callbacks, so this
    // path has no way to await and still has to end up proxied.
    @Test func appliesSynchronouslyForTheLibgit2Transport() async throws {
        let node = FakeNode()
        try await withRouter(node) {
            let configuration = URLSessionConfiguration.default
            let applied = TailnetSessionRouter.shared.applySynchronously(to: configuration)

            #expect(applied == true)
            #expect(configuration.connectionProxyDictionary?["stubProxyHost"] as? String == "127.0.0.1")
        }
    }

    // The synchronous path reports a bypass rather than throwing, so the
    // transport can log it and refuse the request itself.
    @Test func reportsASynchronousFailureAsNotApplied() async throws {
        try await withRouter(FakeNode(shouldFail: true)) {
            #expect(TailnetSessionRouter.shared.applySynchronously(to: URLSessionConfiguration.default) == false)
        }
    }

    // A LAN deployment must not pay for a blocking hop that cannot help it.
    @Test func synchronousPathIsANoOpWithoutANode() async throws {
        try await withRouter(nil) {
            let configuration = URLSessionConfiguration.default
            #expect(TailnetSessionRouter.shared.applySynchronously(to: configuration) == false)
            #expect(configuration.connectionProxyDictionary == nil)
        }
    }

    // Callers pass a base configuration carrying their own timeouts and cache
    // policy, which the router must not discard while adding the proxy.
    @Test func preservesTheCallerSConfiguration() async throws {
        try await withRouter(FakeNode()) {
            let base = URLSessionConfiguration.default
            base.timeoutIntervalForRequest = 42
            base.urlCache = nil

            let routed = try await TailnetSessionRouter.shared.configuration(basedOn: base)

            #expect(routed.timeoutIntervalForRequest == 42)
            #expect(routed.connectionProxyDictionary != nil)
        }
    }

    // Copying rather than mutating matters because GitLFS accepts a
    // caller-owned configuration, and tests inject protocol classes into it.
    @Test func doesNotMutateTheBaseConfiguration() async throws {
        try await withRouter(FakeNode()) {
            let base = URLSessionConfiguration.default
            _ = try await TailnetSessionRouter.shared.configuration(basedOn: base)

            #expect(base.connectionProxyDictionary == nil)
        }
    }

    // Re-pairing a device replaces the node. The router has to follow, or
    // traffic keeps going through a node holding a revoked credential.
    @Test func replacesTheInstalledNode() async throws {
        let first = FakeNode(proxyHost: "127.0.0.1")
        let second = FakeNode(proxyHost: "127.0.0.2")

        TailnetSessionRouter.shared.use(first)
        TailnetSessionRouter.shared.use(second)
        defer { TailnetSessionRouter.shared.use(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        _ = try await TailnetSessionRouter.shared.apply(to: configuration)

        #expect(first.applyCount == 0)
        #expect(second.applyCount == 1)
    }

    // Leaving a tailnet must stop later sessions from being proxied at a port
    // nothing is listening on any more.
    @Test func clearingTheNodeStopsProxying() async throws {
        TailnetSessionRouter.shared.use(FakeNode())
        TailnetSessionRouter.shared.use(nil)

        #expect(TailnetSessionRouter.shared.isActive == false)
        let configuration = URLSessionConfiguration.ephemeral
        #expect(try await TailnetSessionRouter.shared.apply(to: configuration) == false)
    }
}
