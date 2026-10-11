import Foundation
import Network
import Testing
@testable import LibGit2

/// Documents the TailscaleKit contract the join snapshot has to follow.
///
/// `proxyVia` writes `proxyConfigurations` and leaves
/// `connectionProxyDictionary` empty. Reading the older property is what
/// made every rejoin shut the node down as `missingProxy`.
struct TailnetProxySnapshotTests {
    @Test func capturesModernProxyConfigurations() {
        let configuration = URLSessionConfiguration.ephemeral
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 1080)
        var proxy = ProxyConfiguration(socksv5Proxy: endpoint)
        proxy.applyCredential(username: "tsnet", password: "secret")
        configuration.proxyConfigurations = [proxy]

        let captured = TailnetManager.capturedProxyConfigurations(from: configuration)
        #expect(captured?.count == 1)
    }

    // A configuration that only has the CFNetwork dictionary is how the
    // first snapshot implementation saw a successful proxyVia: the modern
    // array was populated, the dictionary was not, and join aborted.
    @Test func ignoresTheLegacyProxyDictionary() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["stubProxyHost": "127.0.0.1"]

        #expect(TailnetManager.capturedProxyConfigurations(from: configuration) == nil)
    }

    @Test func appliesCapturedConfigurationsOntoASession() {
        let source = URLSessionConfiguration.ephemeral
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 1080)
        source.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]

        let dest = URLSessionConfiguration.ephemeral
        #expect(TailnetManager.applyCapturedProxy(source.proxyConfigurations, to: dest))
        #expect(dest.proxyConfigurations.count == 1)
    }
}
