import Testing
@testable import iosapp

// Verifies local-network preflight only runs for onboarding targets that
// require LAN access, preventing unnecessary permission prompts.
struct LocalNetworkPermissionManagerTests {
    // Ensures .local hosts require preflight so LAN Git servers can trigger
    // iOS local-network permission before the first connection attempt.
    @Test func localDomainRequiresPreflight() {
        #expect(
            LocalNetworkPermissionManager.shouldRequestPermission(
                gitServerURL: "https://replycant.local:8443/repo.git",
                lfsServerURL: "https://replycant.local:8443/lfs"
            )
        )
    }

    // Ensures private IPv4 endpoints require preflight because they are local
    // network targets subject to privacy gating.
    @Test func privateIPv4RequiresPreflight() {
        #expect(
            LocalNetworkPermissionManager.shouldRequestPermission(
                gitServerURL: "https://192.168.1.20:8443/repo.git",
                lfsServerURL: "https://192.168.1.20:8443/lfs"
            )
        )
    }

    // Ensures link-local IPv6 endpoints require preflight to cover mDNS-like
    // local routing environments.
    @Test func linkLocalIPv6RequiresPreflight() {
        #expect(
            LocalNetworkPermissionManager.shouldRequestPermission(
                gitServerURL: "https://[fe80::1]:8443/repo.git",
                lfsServerURL: nil
            )
        )
    }

    // Ensures single-label hostnames are treated as local targets because they
    // typically resolve via LAN DNS/search domains.
    @Test func singleLabelHostnameRequiresPreflight() {
        #expect(
            LocalNetworkPermissionManager.shouldRequestPermission(
                gitServerURL: "https://gitbox:8443/repo.git",
                lfsServerURL: "https://lfsbox:8443/lfs"
            )
        )
    }

    // Ensures public hostnames skip preflight so internet-hosted libraries do
    // not show irrelevant local-network prompts.
    @Test func publicHostsSkipPreflight() {
        #expect(
            !LocalNetworkPermissionManager.shouldRequestPermission(
                gitServerURL: "https://git.example.com/repo.git",
                lfsServerURL: "https://lfs.example.com"
            )
        )
    }

    // Ensures malformed URLs do not force local-network prompts and can still
    // be handled by existing onboarding validation/error paths.
    @Test func malformedURLsSkipPreflight() {
        #expect(
            !LocalNetworkPermissionManager.shouldRequestPermission(
                gitServerURL: "not-a-url",
                lfsServerURL: "still-not-a-url"
            )
        )
    }

    // Ensures a local LFS endpoint alone still triggers preflight because
    // media syncing depends on LAN access after onboarding completes.
    @Test func localLFSRequiresPreflightEvenWithPublicGitHost() {
        #expect(
            LocalNetworkPermissionManager.shouldRequestPermission(
                gitServerURL: "https://git.example.com/repo.git",
                lfsServerURL: "https://10.0.0.25:8443/lfs"
            )
        )
    }

    // Ensures LAN git URLs keep explicit ports so the permission probe reaches
    // the same target service used for clone traffic.
    @Test func localEndpointPrefersGitHostWithExplicitPort() {
        let endpoint = LocalNetworkPermissionManager.localNetworkEndpoint(
            gitServerURL: "https://192.168.1.20:8443/repo.git",
            lfsServerURL: "https://10.0.0.25:8443/lfs"
        )

        #expect(endpoint?.host == "192.168.1.20")
        #expect(endpoint?.port == 8443)
    }

    // Ensures URLs without explicit ports still probe expected defaults so the
    // permission check remains protocol-aligned.
    @Test func localEndpointUsesSchemeDefaultPorts() {
        let httpsEndpoint = LocalNetworkPermissionManager.localNetworkEndpoint(
            gitServerURL: "https://gitbox/repo.git",
            lfsServerURL: nil
        )
        let httpEndpoint = LocalNetworkPermissionManager.localNetworkEndpoint(
            gitServerURL: "https://git.example.com/repo.git",
            lfsServerURL: "http://10.0.0.25/path"
        )

        #expect(httpsEndpoint?.host == "gitbox")
        #expect(httpsEndpoint?.port == 443)
        #expect(httpEndpoint?.host == "10.0.0.25")
        #expect(httpEndpoint?.port == 80)
    }

    // Ensures public git hosts can fall back to local LFS targets so LAN media
    // endpoints still trigger preflight when git itself is internet hosted.
    @Test func localEndpointFallsBackToLFSWhenGitIsPublic() {
        let endpoint = LocalNetworkPermissionManager.localNetworkEndpoint(
            gitServerURL: "https://git.example.com/repo.git",
            lfsServerURL: "https://10.0.0.25:8443/lfs"
        )

        #expect(endpoint?.host == "10.0.0.25")
        #expect(endpoint?.port == 8443)
    }

    // Ensures entirely public endpoint configurations skip preflight probes and
    // avoid irrelevant local-network permission requests.
    @Test func localEndpointReturnsNilForPublicHosts() {
        #expect(
            LocalNetworkPermissionManager.localNetworkEndpoint(
                gitServerURL: "https://git.example.com/repo.git",
                lfsServerURL: "https://lfs.example.com"
            ) == nil
        )
    }

    // Ensures malformed endpoint values do not create bogus probe targets and
    // continue through existing validation/error handling paths.
    @Test func localEndpointReturnsNilForMalformedURLs() {
        #expect(
            LocalNetworkPermissionManager.localNetworkEndpoint(
                gitServerURL: "not-a-url",
                lfsServerURL: "still-not-a-url"
            ) == nil
        )
    }

    // Ensures generic endpoint lists detect LAN discovery hosts used by recovery.
    @Test func endpointListPrefersFirstLocalHost() {
        let endpoint = LocalNetworkPermissionManager.localNetworkEndpoint(
            endpointURLs: [
                "https://git.example.com/repo.git",
                "http://replycant.local:8080/config.json",
                "https://10.0.0.25:8443/lfs"
            ]
        )

        #expect(endpoint?.host == "replycant.local")
        #expect(endpoint?.port == 8080)
    }

    // Ensures endpoint lists without LAN hosts skip permission probing entirely.
    @Test func endpointListReturnsNilForPublicHosts() {
        #expect(
            LocalNetworkPermissionManager.localNetworkEndpoint(
                endpointURLs: [
                    "https://git.example.com/repo.git",
                    "https://lfs.example.com"
                ]
            ) == nil
        )
    }
}
