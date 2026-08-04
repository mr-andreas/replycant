import Testing
@testable import iosapp

// Verifies webapp CA-hash branching behavior so linking only proceeds for the configured trusted server.
struct DeviceLinkingViewTests {
    // Confirms iOS-to-iOS linking (without ca_hash) bypasses webapp CA verification.
    @Test func noScannedHashAlwaysMatches() {
        #expect(DeviceLinkingView.isMatchingWebappCAHash(scannedCAHash: nil, configuredCAHash: nil))
        #expect(DeviceLinkingView.isMatchingWebappCAHash(scannedCAHash: nil, configuredCAHash: "abc"))
    }

    // Confirms mismatched or missing configured hash rejects webapp authorization attempts.
    @Test func scannedHashRequiresMatchingConfiguredHash() {
        #expect(DeviceLinkingView.isMatchingWebappCAHash(scannedCAHash: "abc", configuredCAHash: "abc"))
        #expect(DeviceLinkingView.isMatchingWebappCAHash(scannedCAHash: "ABC", configuredCAHash: "abc"))
        #expect(!DeviceLinkingView.isMatchingWebappCAHash(scannedCAHash: "abc", configuredCAHash: nil))
        #expect(!DeviceLinkingView.isMatchingWebappCAHash(scannedCAHash: "abc", configuredCAHash: "def"))
    }
}
