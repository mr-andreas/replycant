import Foundation
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
            caPEM: "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n",
            preauthKey: "hskey-auth-example"
        )
    }

    // The pre-auth key is single-use and expires in minutes, and the node's key
    // material persists in the tsnet state directory, so a durable copy of the
    // credential would be risk with no benefit.
    @Test func theCredentialIsNeverPersisted() throws {
        let (manager, defaults) = Self.manager()

        manager.save(try TailnetConfigurationManager.from(payload: Self.payload()))

        let raw = try #require(defaults.data(forKey: "replycant.tailnet.config"))
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.contains("hskey-auth-example"))
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

    @Test func reportsNoConfigurationBeforePairing() {
        let (manager, _) = Self.manager()
        #expect(manager.load() == nil)
    }

    // A corrupted entry must degrade to "not on a tailnet" rather than
    // blocking startup, since a LAN deployment would still work.
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
    // LAN deployments were onboarded without a tailnet and must keep working
    // untouched, so a device with nothing stored has nothing to join.
    @Test func doesNothingWhenTheDeviceIsNotPairedToATailnet() async throws {
        let defaults = UserDefaults(suiteName: "replycant.tests.tailnet.\(UUID().uuidString)")!
        let bootstrap = TailnetBootstrap(
            configurations: TailnetConfigurationManager(defaults: defaults)
        )

        #expect(await bootstrap.isConfigured == false)
        // Must not throw: a LAN device reaches this on every launch.
        try await bootstrap.ensureJoinedIfConfigured()
        // Settings hides Connection when there is no node; a thrown
        // status here would be indistinguishable from a joined device
        // whose local API failed.
        #expect(await bootstrap.status() == nil)
    }
}
