import Foundation
import LibGit2
import Testing
@testable import iosapp

// Covers what survives a restart on a tailnet deployment.
//
// A userspace node only runs while the app does, so every launch is a rejoin.
// If this store loses or mangles the deployment's coordinates the device cannot
// get back onto the tailnet, and gitd publishes no other way in.
struct TailnetConfigurationManagerTests {
    private static func manager() -> (TailnetConfigurationManager, UserDefaults) {
        // A per-test suite, so one test's stored configuration cannot make
        // another pass or fail.
        let name = "replycant.tests.tailnet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (TailnetConfigurationManager(defaults: defaults), defaults)
    }

    private static func payload(
        headscaleURL: String = "https://abc123.tunnel.replycant.com"
    ) -> PairingRecord.Payload {
        PairingRecord.Payload(
            headscaleURL: headscaleURL,
            caPEM: "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n"
        )
    }

    @Test func roundTripsAConfiguration() throws {
        let (manager, _) = Self.manager()
        let configuration = try TailnetConfigurationManager.from(payload: Self.payload())

        manager.save(configuration)

        #expect(manager.load() == configuration)
    }

    // The shim speaks TLS straight to hsproxy, so it needs a port. The URL form
    // only exists because that is how headscale advertises itself.
    @Test func derivesTheDefaultPortFromTheScheme() throws {
        let https = try TailnetConfigurationManager.from(payload: Self.payload())
        #expect(https.headscalePort == 443)

        let http = try TailnetConfigurationManager.from(
            payload: Self.payload(headscaleURL: "http://headscale.example.com")
        )
        #expect(http.headscalePort == 80)
    }

    // Manual-exposure deployments forward an arbitrary router port, so an
    // explicit one has to survive.
    @Test func keepsAnExplicitPort() throws {
        let configuration = try TailnetConfigurationManager.from(
            payload: Self.payload(headscaleURL: "https://headscale.example.com:8443")
        )
        #expect(configuration.headscalePort == 8443)
        #expect(configuration.headscaleHost == "headscale.example.com")
    }

    // MagicDNS resolves this inside the tailnet and gitd's certificate carries
    // the matching SAN, which is what lets the existing mTLS transport work
    // over the tailnet unchanged.
    @Test func rebuildsTheGitdURLWithoutThePairingRecord() throws {
        let configuration = try TailnetConfigurationManager.from(payload: Self.payload())
        #expect(TailnetConfiguration.gitdURL == "https://gitd.replycant.internal:8443")
    }

    // gitd's tailnet listener is not on 443, and the headscale policy only
    // opens the ports gitd actually serves, so an implied port would be denied
    // by the tailnet before it ever reached gitd.
    @Test func namesThePortGitdServesOn() throws {
        let configuration = try TailnetConfigurationManager.from(payload: Self.payload())
        #expect(TailnetConfiguration.gitdURL.hasSuffix(":\(TailnetConfiguration.gitdPort)"))
    }

    // A recovery key records where the control plane is so a fresh phone can
    // rejoin. The URL has to parse back to the same host and port, or the
    // restored phone would dial somewhere else.
    @Test func rebuildsTheHeadscaleURLItWasDerivedFrom() throws {
        let standard = try TailnetConfigurationManager.from(payload: Self.payload())
        #expect(standard.headscaleURL == "https://abc123.tunnel.replycant.com")
        #expect(try TailnetConfigurationManager.from(headscaleURL: standard.headscaleURL) == standard)

        let forwarded = try TailnetConfigurationManager.from(
            payload: Self.payload(headscaleURL: "https://headscale.example.com:8443")
        )
        #expect(forwarded.headscaleURL == "https://headscale.example.com:8443")
        #expect(try TailnetConfigurationManager.from(headscaleURL: forwarded.headscaleURL) == forwarded)
    }

    @Test func reportsNoConfigurationBeforePairing() {
        let (manager, _) = Self.manager()
        #expect(manager.load() == nil)
    }

    // A corrupted entry must degrade to "not paired" rather than blocking
    // startup, so the local library stays usable and the device can re-pair.
    @Test func treatsUnreadableStorageAsNoConfiguration() {
        let (manager, defaults) = Self.manager()
        defaults.set(Data("not json".utf8), forKey: "replycant.tailnet.config")

        #expect(manager.load() == nil)
    }

    @Test func clearsTheConfiguration() throws {
        let (manager, _) = Self.manager()
        manager.save(try TailnetConfigurationManager.from(payload: Self.payload()))

        manager.clear()

        #expect(manager.load() == nil)
    }

    // A record whose headscale URL cannot be parsed would leave the device
    // rejoining an address it can never reach, so it is refused where the
    // record is opened rather than at the first failed connection.
    @Test func refusesAnUnparseableHeadscaleURL() {
        #expect(throws: PairingRecord.PairingError.malformedHeadscaleURL) {
            try TailnetConfigurationManager.from(
                payload: Self.payload(headscaleURL: "headscale.example.com")
            )
        }
    }
}

// Covers the decision to join, which is the part that can be tested without a
// real WireGuard node.
struct TailnetBootstrapTests {
    // Every launch before pairing reaches this, and a device with nothing
    // stored has nothing to join.
    @Test func doesNothingWhenTheDeviceIsNotPairedToATailnet() async throws {
        let defaults = UserDefaults(suiteName: "replycant.tests.tailnet.\(UUID().uuidString)")!
        let bootstrap = TailnetBootstrap(
            configurations: TailnetConfigurationManager(defaults: defaults)
        )

        #expect(await bootstrap.isConfigured == false)
        // Must not throw, or launch would fail before onboarding.
        try await bootstrap.ensureJoinedIfConfigured()
        // Settings hides Connection when there is no node; a thrown
        // status here would be indistinguishable from a joined device
        // whose local API failed.
        #expect(await bootstrap.status() == nil)
    }

    private static func configuredStore() throws -> TailnetConfigurationManager {
        let defaults = UserDefaults(suiteName: "replycant.tests.tailnet.\(UUID().uuidString)")!
        let store = TailnetConfigurationManager(defaults: defaults)
        store.save(try TailnetConfigurationManager.from(headscaleURL: "https://abc123.tunnel.example.com"))
        return store
    }

    // libtailscale cannot cancel a node that is coming up, so offline, or
    // with the server or relay down, the join never returns. Launch must
    // still reach the local library, and the join keeps going so the device
    // gets back on once the network does.
    @Test func launchContinuesWhenTheJoinCannotFinish() async throws {
        let probe = JoinProbe()
        let router = TailnetSessionRouter()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: router,
            rejoin: { _ in
                _ = await probe.begin()
                await probe.waitForRelease()
            }
        )

        await #expect(throws: TailnetBootstrap.BootstrapError.stillConnecting) {
            try await bootstrap.ensureJoinedIfConfigured(timeout: .milliseconds(50))
        }
        // Requests made meanwhile are refused rather than dialled directly.
        #expect(router.applySynchronously(to: .ephemeral) == false)

        // A second caller shares the join in flight. Starting another would
        // put two nodes on one state directory.
        await #expect(throws: TailnetBootstrap.BootstrapError.stillConnecting) {
            try await bootstrap.ensureJoinedIfConfigured(timeout: .milliseconds(50))
        }
        #expect(await probe.attempts == 1)

        await probe.release()
    }

    // An online launch waits for the node, so the first sync and image loads
    // never start into a burst of refused requests.
    @Test func aJoinThatFinishesInTimeReturnsNormally() async throws {
        let probe = JoinProbe()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: TailnetSessionRouter(),
            rejoin: { _ in _ = await probe.begin() }
        )

        try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))

        #expect(await probe.attempts == 1)
    }

    // A join that failed outright is over, so the next call has to try
    // again rather than keep reporting the old failure.
    @Test func aFailedJoinIsRetriedByTheNextCall() async throws {
        let probe = JoinProbe()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: TailnetSessionRouter(),
            rejoin: { _ in
                _ = await probe.begin()
                if await probe.attempts == 1 {
                    throw TailnetManager.TailnetError.notJoined
                }
            }
        )

        await #expect(throws: TailnetManager.TailnetError.notJoined) {
            try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))
        }
        try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))

        #expect(await probe.attempts == 2)
    }

    // A locked phone can drop the loopback proxy while status still says
    // Running. Coming back after that has to build a new node, once.
    @Test func aLongBackgroundStayRebuildsTheNodeOnce() async throws {
        let clock = ManualClock()
        let probe = JoinProbe()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: TailnetSessionRouter(),
            rejoin: { _ in _ = await probe.begin() },
            clock: { clock.current() }
        )
        try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))

        await bootstrap.noteEnteredBackground()
        clock.advance(by: TailnetBootstrap.suspendRebuildThreshold)
        try await bootstrap.noteReturnedToForeground()

        #expect(await probe.attempts == 2)
        try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))
        #expect(await probe.attempts == 2)
    }

    // A quick app switch does not suspend the process, so rebuilding would
    // only interrupt a connection that is still fine.
    @Test func aShortBackgroundStayLeavesTheNodeRunning() async throws {
        let clock = ManualClock()
        let probe = JoinProbe()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: TailnetSessionRouter(),
            rejoin: { _ in _ = await probe.begin() },
            clock: { clock.current() }
        )
        try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))

        await bootstrap.noteEnteredBackground()
        clock.advance(by: TailnetBootstrap.suspendRebuildThreshold - 1)
        try await bootstrap.noteReturnedToForeground()

        #expect(await probe.attempts == 1)
    }

    // An upload that starts while the wake rebuild is in flight has to wait
    // on that rebuild. Starting another join would put two nodes on one
    // state directory.
    @Test func aSyncDuringRebuildWaitsOnTheSameJoin() async throws {
        let clock = ManualClock()
        let probe = JoinProbe()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: TailnetSessionRouter(),
            rejoin: { _ in
                _ = await probe.begin()
                if await probe.attempts > 1 {
                    await probe.waitForRelease()
                }
            },
            clock: { clock.current() }
        )
        try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))

        await bootstrap.noteEnteredBackground()
        clock.advance(by: TailnetBootstrap.suspendRebuildThreshold + 5)
        let wake = Task {
            try await bootstrap.noteReturnedToForeground()
        }
        #expect(await probe.waitUntilAttempts(reach: 2))

        let sync = Task {
            try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))
        }
        // Let the sync attach to the join already in flight before it ends.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.attempts == 2)
        await probe.release()
        try await wake.value
        try await sync.value

        #expect(await probe.attempts == 2)
    }

    // A join still inside up() when the phone locks has had its loopback
    // sockets reclaimed. The next long wake has to start a new join; waiting
    // on the old one never reaches Running.
    @Test func aLongWakeReplacesAJoinStillInFlight() async throws {
        let clock = ManualClock()
        let probe = JoinProbe()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: TailnetSessionRouter(),
            rejoin: { _ in
                let attempt = await probe.begin()
                if attempt == 1 {
                    await probe.waitForRelease()
                }
            },
            clock: { clock.current() }
        )

        await #expect(throws: TailnetBootstrap.BootstrapError.stillConnecting) {
            try await bootstrap.ensureJoinedIfConfigured(timeout: .milliseconds(50))
        }

        await bootstrap.noteEnteredBackground()
        clock.advance(by: TailnetBootstrap.suspendRebuildThreshold)
        try await bootstrap.noteReturnedToForeground()

        #expect(await probe.attempts == 2)
        try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))
        #expect(await probe.attempts == 2)

        // The first join stands in for one that never reaches Running.
        // Releasing it only lets the test process finish.
        await probe.release()
    }

    // The replaced join can still finish, late, after its sockets are gone.
    // That completion must not drop the replacement or look like the device
    // is back on the tailnet before the replacement has succeeded.
    @Test func aReplacedJoinFinishingLateDoesNotClearTheNewOne() async throws {
        let clock = ManualClock()
        let probe = JoinProbe()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: TailnetSessionRouter(),
            rejoin: { _ in
                let attempt = await probe.begin()
                await probe.waitForRelease()
                if attempt == 1 {
                    throw TailnetManager.TailnetError.notJoined
                }
            },
            clock: { clock.current() }
        )

        await #expect(throws: TailnetBootstrap.BootstrapError.stillConnecting) {
            try await bootstrap.ensureJoinedIfConfigured(timeout: .milliseconds(50))
        }

        await bootstrap.noteEnteredBackground()
        clock.advance(by: TailnetBootstrap.suspendRebuildThreshold)
        let wake = Task {
            try await bootstrap.noteReturnedToForeground()
        }
        #expect(await probe.waitUntilAttempts(reach: 2))

        await probe.releaseNext()
        // Let the replaced join finish and try to publish itself before the
        // sync attaches.
        try await Task.sleep(for: .milliseconds(50))

        let sync = Task {
            try await bootstrap.ensureJoinedIfConfigured(timeout: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.attempts == 2)
        await #expect(throws: TailnetBootstrap.BootstrapError.stillConnecting) {
            try await sync.value
        }

        await probe.release()
        try await wake.value
        try await bootstrap.ensureJoinedIfConfigured(timeout: .seconds(5))
        #expect(await probe.attempts == 2)
    }

    // A fullscreen photo opened during the join is refused once the
    // launch timeout passes. This wait is what lets that photo try
    // again when the join later finishes, instead of stopping there.
    @Test func waitUntilJoinedOutlastsTheLaunchTimeout() async throws {
        let probe = JoinProbe()
        let bootstrap = TailnetBootstrap(
            configurations: try Self.configuredStore(),
            router: TailnetSessionRouter(),
            rejoin: { _ in
                _ = await probe.begin()
                await probe.waitForRelease()
            }
        )

        let finished = FinishFlag()
        let wait = Task {
            try await bootstrap.waitUntilJoined(pollTimeout: .milliseconds(50))
            await finished.mark()
        }

        try await Task.sleep(for: .milliseconds(200))
        #expect(await probe.attempts == 1)
        #expect(await finished.isSet == false)

        await probe.release()
        try await wait.value
        #expect(await finished.isSet)
    }

    // A device that has not paired has nothing to join. Waiting would
    // leave the photo spinner up for a connection that never comes.
    @Test func waitUntilJoinedThrowsWhenTheDeviceHasNoTailnet() async {
        let defaults = UserDefaults(suiteName: "replycant.tests.tailnet.\(UUID().uuidString)")!
        let bootstrap = TailnetBootstrap(
            configurations: TailnetConfigurationManager(defaults: defaults)
        )

        await #expect(throws: TailnetSessionRouter.RoutingError.notConnectedYet) {
            try await bootstrap.waitUntilJoined()
        }
    }

}

/// Set when a join wait returns, so a test can see that several poll
/// timeouts have passed without awaiting the wait itself.
private actor FinishFlag {
    private(set) var isSet = false

    func mark() {
        isSet = true
    }
}

/// A clock tests can move forward without sleeping for the suspend threshold.
private final class ManualClock: @unchecked Sendable {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    func current() -> Date { now }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Counts join attempts and can hold one open until released, standing in
/// for a node whose `up()` cannot finish while the device is offline.
private actor JoinProbe {
    private(set) var attempts = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Records one join attempt and reports which one it is, so a test can
    /// fail only the join a wake replaced.
    func begin() -> Int {
        attempts += 1
        return attempts
    }

    /// Lets the oldest held join finish while later ones stay blocked, so a
    /// replaced join can fail after its replacement has already started.
    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilAttempts(reach count: Int) async -> Bool {
        for _ in 0..<200 {
            if attempts >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
