import Foundation
import Network
import Security
import Testing
@testable import GitDB
@testable import LibGit2

// Covers the key request the shim sends to hsproxy.
//
// A device mints its tailnet key through the shim's own loopback listener, so
// the request gets the pinned CA and the device certificate. Neither upstream
// here completes a TLS handshake: what matters is that the request left
// through the shim, not that Network framework finished the handshake.
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
                // Held rather than cancelled so the shim's dial counts as an
                // accept instead of failing before the test can observe it.
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

    // A device mints its tailnet key through the shim's own loopback listener,
    // so before the shim listens there is nowhere to send the request.
    @Test func mintingAKeyBeforeTheShimStartsFails() async throws {
        let relay = try await RecordingListener.started()
        defer { relay.stop() }

        let shim = HeadscaleControlShim(
            upstreamHost: "127.0.0.1",
            upstreamPort: relay.port,
            trust: .pinned(try Self.deploymentCA()),
            clientIdentity: try Self.deviceIdentity()
        )

        await #expect(throws: HeadscaleControlShim.ShimError.notStarted) {
            _ = try await shim.mintPreauthKey()
        }
        #expect(relay.acceptCount == 0)
    }

    // The key request has to take the same pinned-CA path as control traffic,
    // since hsproxy only grants keys to a device certificate it can see.
    @Test func mintingAKeyGoesThroughTheShim() async throws {
        let relay = try await RecordingListener.started()
        defer { relay.stop() }

        let shim = HeadscaleControlShim(
            upstreamHost: "127.0.0.1",
            upstreamPort: relay.port,
            trust: .pinned(try Self.deploymentCA()),
            clientIdentity: try Self.deviceIdentity()
        )
        try await shim.start()
        defer { shim.stop() }

        // The relay never completes the handshake, so the request itself
        // fails; what matters is that it left through the shim's upstream.
        let mint = Task { try await shim.mintPreauthKey() }
        defer { mint.cancel() }

        #expect(await relay.waitForAccept(atLeast: 1, within: 5),
                "the key request must reach hsproxy through the shim")
    }
}
