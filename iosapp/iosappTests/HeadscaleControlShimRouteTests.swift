import Foundation
import Network
import Security
import Testing
@testable import GitDB
@testable import LibGit2

// Covers which way the headscale shim reaches the control plane.
//
// The hosted relay is a bootstrap dependency: a device with no tailnet has no
// other way to talk to the control plane. Once it is a member it should stop
// using the relay, because otherwise every household stays permanently
// dependent on a service replycant operates. These tests pin down that the
// tailnet is tried first, and that a device whose tailnet path is broken still
// reaches the control plane instead of being stranded.
//
// Neither upstream here completes a TLS handshake, and that is deliberate: the
// subject is route selection, and standing up two mTLS servers signed by a
// pinned CA would test Network framework rather than the shim.
@MainActor
@Suite(.sharedAppState)
struct HeadscaleControlShimRouteTests {
    // A loopback listener that accepts and then does nothing, so a test can
    // observe that the shim dialled it without also having to answer.
    private final class RecordingListener {
        let listener: NWListener
        private let queue = DispatchQueue(label: "com.replycant.route-test-listener")
        private let lock = NSLock()
        private var accepted = 0
        private var held: [NWConnection] = []

        private init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters, on: .any)
        }

        // Returns only once the kernel has assigned a port. Reading `port`
        // before that yields 0, which the shim would then dial and fail on for
        // reasons unrelated to what is being tested.
        static func started() async throws -> RecordingListener {
            let recorder = try RecordingListener()
            recorder.listener.newConnectionHandler = { [weak recorder] connection in
                guard let recorder else { return }
                // Held rather than cancelled: cancelling would let the shim's
                // attempt fail early, and the timeout is part of what is
                // being tested.
                connection.start(queue: recorder.queue)
                recorder.lock.lock()
                recorder.accepted += 1
                recorder.held.append(connection)
                recorder.lock.unlock()
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                recorder.listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume()
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                recorder.listener.start(queue: recorder.queue)
            }
            return recorder
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }

        var acceptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return accepted
        }

        func stop() {
            listener.cancel()
            lock.lock()
            let open = held
            held.removeAll()
            lock.unlock()
            open.forEach { $0.cancel() }
        }

        // Polls rather than blocking on a continuation, because a connection
        // that never arrives must fail the test rather than hang the suite.
        func waitForAccept(atLeast count: Int, within seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if acceptCount >= count { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return acceptCount >= count
        }
    }

    private static func deploymentCA() throws -> SecCertificate {
        let der = try #require(Data(base64Encoded: HeadscaleControlShimTrustTests.deploymentCADER))
        return try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    // Any identity will do: no handshake in these tests gets far enough for
    // the far side to look at it.
    private static func deviceIdentity() throws -> SecIdentity {
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "route-test-device")
        return try #require(ClientIdentityManager.shared.loadSecIdentity())
    }

    // Opens one control connection through the shim and leaves it open, since
    // closing it would tear down the attempt being observed.
    private func openControlConnection(to port: UInt16) -> NWConnection {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.start(queue: .global())
        // Something has to be written for the shim to have a session worth
        // relaying, and for the far side to see a connection at all.
        connection.send(content: Data("GET /key?v=120\r\n".utf8), completion: .idempotent)
        return connection
    }

    // The point of the whole phase: a device that is already on the tailnet
    // must not keep routing control traffic through replycant's hosted relay.
    @Test func tailnetRouteIsTriedBeforeTheRelay() async throws {
        let socksProxy = try await RecordingListener.started()
        let relay = try await RecordingListener.started()
        defer {
            socksProxy.stop()
            relay.stop()
        }

        let shim = HeadscaleControlShim(
            upstreamHost: "127.0.0.1",
            upstreamPort: relay.port,
            pinnedCA: try Self.deploymentCA(),
            clientIdentity: try Self.deviceIdentity()
        )
        try await shim.start()
        defer { shim.stop() }

        try shim.setTailnetRoute(HeadscaleControlShim.TailnetRoute(
            host: "gitd.replycant.internal",
            port: 8444,
            socksProxy: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: socksProxy.port)!),
            socksUsername: "tsnet",
            socksPassword: "credential"
        ))

        let control = openControlConnection(to: try #require(shim.port))
        defer { control.cancel() }

        #expect(await socksProxy.waitForAccept(atLeast: 1, within: 5),
                "the tailnet route must be attempted through the node's SOCKS proxy")
        #expect(relay.acceptCount == 0,
                "the relay must not be dialled while the tailnet route is still being tried")
    }

    // The tailnet route depends on the node being up and the server being
    // online. A device whose own tailnet path is broken has to keep working,
    // or a transient WireGuard problem becomes an unrecoverable one.
    @Test func aStalledTailnetRouteFallsBackToTheRelay() async throws {
        let socksProxy = try await RecordingListener.started()
        let relay = try await RecordingListener.started()
        defer {
            socksProxy.stop()
            relay.stop()
        }

        let shim = HeadscaleControlShim(
            upstreamHost: "127.0.0.1",
            upstreamPort: relay.port,
            pinnedCA: try Self.deploymentCA(),
            clientIdentity: try Self.deviceIdentity()
        )
        try await shim.start()
        defer { shim.stop() }

        // The proxy accepts and then never speaks SOCKS, which is how a node
        // that has gone offline behaves: the attempt stalls rather than fails.
        try shim.setTailnetRoute(HeadscaleControlShim.TailnetRoute(
            host: "gitd.replycant.internal",
            port: 8444,
            socksProxy: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: socksProxy.port)!),
            socksUsername: "tsnet",
            socksPassword: "credential"
        ))

        let control = openControlConnection(to: try #require(shim.port))
        defer { control.cancel() }

        #expect(await relay.waitForAccept(atLeast: 1, within: 10),
                "a stalled tailnet route must fall back to the relay rather than stranding the device")
    }

    // Before the node is up there is no tailnet to dial, and attempting one
    // would add the fallback timeout to the very connections the join depends
    // on.
    @Test func bootstrapGoesStraightToTheRelay() async throws {
        let relay = try await RecordingListener.started()
        defer { relay.stop() }

        let shim = HeadscaleControlShim(
            upstreamHost: "127.0.0.1",
            upstreamPort: relay.port,
            pinnedCA: try Self.deploymentCA(),
            clientIdentity: try Self.deviceIdentity()
        )
        try await shim.start()
        defer { shim.stop() }

        let control = openControlConnection(to: try #require(shim.port))
        defer { control.cancel() }

        #expect(await relay.waitForAccept(atLeast: 1, within: 5),
                "with no tailnet route the relay must be dialled immediately")
    }

    // The status view distinguishes "still on the relay" from "nothing has
    // connected yet", and the two mean very different things to a user.
    @Test func noRouteIsReportedBeforeAnythingConnects() async throws {
        let relay = try await RecordingListener.started()
        defer { relay.stop() }

        let shim = HeadscaleControlShim(
            upstreamHost: "127.0.0.1",
            upstreamPort: relay.port,
            pinnedCA: try Self.deploymentCA(),
            clientIdentity: try Self.deviceIdentity()
        )
        try await shim.start()
        defer { shim.stop() }

        #expect(shim.lastRoute == nil)
    }

    // A route with no host would be dialled as an empty name and fail on every
    // connection, silently costing every session the fallback timeout.
    @Test func anEmptyTailnetHostIsRejected() async throws {
        let relay = try await RecordingListener.started()
        defer { relay.stop() }

        let shim = HeadscaleControlShim(
            upstreamHost: "127.0.0.1",
            upstreamPort: relay.port,
            pinnedCA: try Self.deploymentCA(),
            clientIdentity: try Self.deviceIdentity()
        )

        #expect(throws: HeadscaleControlShim.ShimError.self) {
            try shim.setTailnetRoute(HeadscaleControlShim.TailnetRoute(
                host: "  ",
                port: 8444,
                socksProxy: .hostPort(host: .ipv4(.loopback), port: 1080),
                socksUsername: "tsnet",
                socksPassword: "credential"
            ))
        }
    }
}
