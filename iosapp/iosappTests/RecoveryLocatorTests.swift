import Testing
@testable import iosapp

// Covers where a new recovery key tells a future phone to find the deployment.
//
// The bundle is written once and read on a phone that knows nothing else, so
// a locator the phone cannot reach makes the key useless, and nothing notices
// until the day it is needed.
struct RecoveryLocatorTests {
    // A tailnet deployment's discovery page is loopback-only and gitd is
    // tailnet-only, so the control plane is the only thing a fresh phone can
    // reach. Writing the discovery URL here is the bug that made tailnet
    // recovery stop at "discovery server unreachable".
    @Test func tailnetDeploymentRecordsTheControlPlane() {
        let locator = RecoveryKeyManager.recoveryLocator(
            gitURL: TailnetConfiguration.gitdURL,
            tailnet: TailnetConfiguration(headscaleHost: "abc123.tunnel.example.com", headscalePort: 443)
        )

        #expect(locator == RecoveryKeyManager.RecoveryLocator(
            discoveryURL: nil,
            headscaleURL: "https://abc123.tunnel.example.com"
        ))
    }

    // A LAN deployment still serves its CA page next to gitd.
    @Test func lanDeploymentRecordsTheDiscoveryPage() {
        let locator = RecoveryKeyManager.recoveryLocator(
            gitURL: "https://replycant.local:8443",
            tailnet: nil
        )

        #expect(locator == RecoveryKeyManager.RecoveryLocator(
            discoveryURL: "http://replycant.local:8080",
            headscaleURL: nil
        ))
    }
}
