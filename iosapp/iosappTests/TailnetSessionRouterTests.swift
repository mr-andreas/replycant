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
    private(set) var cachedApplyCount = 0
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

    // The production node captures SOCKS settings at join so libgit2
    // callbacks never hop onto the actor. This stub writes the same dict
    // apply() would, which is how tests prove the sync path skipped apply().
    nonisolated func applyCachedProxy(to configuration: URLSessionConfiguration) -> Bool {
        cachedApplyCount += 1
        if shouldFail {
            return false
        }
        configuration.connectionProxyDictionary = ["stubProxyHost": proxyHost]
        return true
    }

    func addresses() async throws -> (ip4: String?, ip6: String?) {
        ("100.64.0.7", nil)
    }

    // The router never reads status; it is here because the settings screen
    // shares the node protocol.
    func status() async throws -> TailnetStatusReport {
        try TailnetStatusReport.decode(
            Data(#"{"BackendState":"Running","TailscaleIPs":["100.64.0.7"]}"#.utf8),
            controlRoute: .tailnet
        )
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

    // gitd is reachable only over the tailnet, so without a node there is
    // nowhere safe to send a request: dialling directly would put it on
    // whatever network the device happens to be on.
    @Test func refusesWithoutANode() async throws {
        try await withRouter(nil) {
            let configuration = URLSessionConfiguration.ephemeral

            await #expect(throws: TailnetSessionRouter.RoutingError.notConnectedYet) {
                try await TailnetSessionRouter.shared.apply(to: configuration)
            }
            #expect(configuration.connectionProxyDictionary == nil)
        }
    }

    // The point of the router: a session built anywhere in the app comes back
    // pointed at the node's proxy.
    @Test func appliesTheProxyToAConfiguration() async throws {
        let node = FakeNode(proxyHost: "127.0.0.1")
        try await withRouter(node) {
            let configuration = URLSessionConfiguration.ephemeral
            try await TailnetSessionRouter.shared.apply(to: configuration)

            #expect(node.applyCount == 1)
            #expect(configuration.connectionProxyDictionary?["stubProxyHost"] as? String == "127.0.0.1")
        }
    }

    // Dialling directly on failure would leak the request onto whatever
    // network the device is on, and one that resolves the name could
    // reach a host the user never authorized.
    @Test func propagatesAFailureInsteadOfDiallingDirectly() async throws {
        let node = FakeNode(shouldFail: true)
        TailnetSessionRouter.shared.use(node)
        defer { TailnetSessionRouter.shared.use(nil) }

        await #expect(throws: TailnetManager.TailnetError.notJoined) {
            try await TailnetSessionRouter.shared.apply(to: URLSessionConfiguration.ephemeral)
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

    // User-initiated git fetch and User-interactive playback wait on this
    // path. Calling async apply() from a default-QoS Task.detached is the
    // priority inversion those stacks report, so the cache must be enough.
    @Test func synchronousPathUsesTheCachedProxyWithoutCallingApply() async throws {
        let node = FakeNode()
        try await withRouter(node) {
            let configuration = URLSessionConfiguration.default
            let applied = TailnetSessionRouter.shared.applySynchronously(to: configuration)

            #expect(applied == true)
            #expect(node.applyCount == 0)
            #expect(node.cachedApplyCount == 1)
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

    // The libgit2 transport refuses on this answer, so it must report the
    // missing node rather than hand back an unproxied configuration.
    @Test func synchronousPathRefusesWithoutANode() async throws {
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
        try await TailnetSessionRouter.shared.apply(to: configuration)

        #expect(first.applyCount == 0)
        #expect(second.applyCount == 1)
    }

    // Leaving a tailnet must stop later sessions from being proxied at a port
    // nothing is listening on any more.
    @Test func clearingTheNodeStopsProxying() async throws {
        TailnetSessionRouter.shared.use(FakeNode())
        TailnetSessionRouter.shared.use(nil)

        let configuration = URLSessionConfiguration.ephemeral
        await #expect(throws: TailnetSessionRouter.RoutingError.notConnectedYet) {
            try await TailnetSessionRouter.shared.apply(to: configuration)
        }
        #expect(configuration.connectionProxyDictionary == nil)
    }
}

/// Covers the window between launch and the node coming up.
///
/// Launch no longer waits indefinitely for the join, so requests can be
/// issued while it is still in flight. Each test uses its own router so the
/// missing node never leaks into suites running against the shared one.
@Suite(.serialized)
struct TailnetSessionRouterPendingTests {
    // Requests issued during the background join must start working as soon
    // as the node arrives, without the caller having to retry differently.
    @Test func installingANodeEndsTheRefusal() async throws {
        let router = TailnetSessionRouter()
        #expect(router.applySynchronously(to: .default) == false)

        router.use(FakeNode(proxyHost: "127.0.0.1"))

        let configuration = URLSessionConfiguration.ephemeral
        try await router.apply(to: configuration)
        #expect(configuration.connectionProxyDictionary?["stubProxyHost"] as? String == "127.0.0.1")
    }

    // Long-lived sessions compare generations to notice that the node they
    // were built for is gone or has arrived, so every change must bump it.
    @Test func everyRoutingChangeBumpsTheGeneration() {
        let router = TailnetSessionRouter()
        let initial = router.generation

        router.use(nil)
        let cleared = router.generation
        router.use(FakeNode())
        let joined = router.generation
        router.use(nil)

        #expect(cleared > initial)
        #expect(joined > cleared)
        #expect(router.generation > joined)
    }
}

/// Covers how a long-lived LFS client follows the router.
///
/// The timeline and upload screens each keep one GitLFS client for the life
/// of the screen. Built during a background join, a client that captured the
/// proxy at init would stay unproxied for good, so it must pick the routing
/// up when it issues requests instead.
@Suite(.serialized)
struct GitLFSTailnetRoutingTests {
    private static let host = "tailnet-routing-lfs.local"

    private func makeClient(router: TailnetSessionRouter) -> GitLFS {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TailnetRoutingLFSURLProtocol.self]
        return GitLFS(
            serverURL: "https://\(Self.host)/lfs",
            sessionConfiguration: configuration,
            router: router
        )
    }

    // A client created before the node is up fails fast with a clear error,
    // then works once the node arrives without being recreated.
    @Test func clientCreatedWhilePendingWorksOnceTheNodeArrives() async throws {
        let router = TailnetSessionRouter()
        let client = makeClient(router: router)
        TailnetRoutingLFSURLProtocol.reset()

        await #expect(throws: LFSError.self) {
            _ = try await client.downloadData(oid: "missing", size: 1)
        }
        #expect(TailnetRoutingLFSURLProtocol.requestCount == 0)

        let node = FakeNode()
        router.use(node)
        await #expect(throws: LFSError.self) {
            // The stub answers 404 for every object; reaching it is the point.
            _ = try await client.downloadData(oid: "missing", size: 1)
        }
        #expect(TailnetRoutingLFSURLProtocol.requestCount > 0)
        #expect(node.cachedApplyCount == 1)
    }

    // Re-pairing replaces the node, and a session still pointed at the old
    // node's proxy would reach nothing.
    @Test func clientRebuildsItsSessionWhenTheNodeChanges() async throws {
        let router = TailnetSessionRouter()
        let first = FakeNode(proxyHost: "127.0.0.1")
        router.use(first)
        let client = makeClient(router: router)
        TailnetRoutingLFSURLProtocol.reset()

        _ = try? await client.downloadData(oid: "missing", size: 1)
        _ = try? await client.downloadData(oid: "missing", size: 1)
        #expect(first.cachedApplyCount == 1)

        let second = FakeNode(proxyHost: "127.0.0.2")
        router.use(second)
        _ = try? await client.downloadData(oid: "missing", size: 1)
        #expect(second.cachedApplyCount == 1)
        #expect(first.cachedApplyCount == 1)
    }
}

/// Answers every request with a 404, and counts requests so a test can tell
/// whether a client reached the network at all.
private final class TailnetRoutingLFSURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "tailnet-routing-lfs.local"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/vnd.git-lfs+json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
