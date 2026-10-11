import CryptoKit
import Foundation
import Security
import Testing
import LibGit2

// Covers the trust decision the headscale shim makes on every control-plane
// connection.
//
// This is the only thing standing between the device and an impostor control
// plane. The shim dials a subdomain of a shared tunnel domain, so the operator
// of that domain can obtain a publicly trusted certificate for the exact
// hostname the device expects. Accepting the system trust store would therefore
// hand them the device's tailnet. These tests pin that behaviour down, because
// the mistake is invisible at runtime: everything would keep working.
//
// The fixtures are fixed DER blobs rather than certificates generated at test
// time. Generating a chain from Swift means either shelling out or writing an
// X.509 encoder, and neither belongs in a test whose subject is the trust
// decision.
struct HeadscaleControlShimTrustTests {
    // Self-signed CA standing in for a deployment's own CA. Shared with the
    // route tests, which need a plausible pinned anchor but never reach a
    // handshake that uses it.
    static let deploymentCADER = "MIIBijCCATCgAwIBAgIUFORBe7GP9t20GQI2nMOQ4eJ0cccwCgYIKoZIzj0EAwIwIjEgMB4GA1UEAwwXcmVwbHljYW50IGRlcGxveW1lbnQgY2EwIBcNMjYwOTA1MjE1OTMzWhgPMjEyNjA4MTIyMTU5MzNaMCIxIDAeBgNVBAMMF3JlcGx5Y2FudCBkZXBsb3ltZW50IGNhMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/+Ayj16LwpM50vLLBDg92tok5UlqII/AhrTe5EapqyZupe8w8C/zvbIekaV/S2ySEm+QNXfpYvT0IUlZ9DrKFaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFPxeQ8W19P0qsJmALwmx37YkhvfMMAoGCCqGSM49BAMCA0gAMEUCIBPgvyIy3bxzjqNgZSUEAh/XfwVQGPhYgGbOL7Cf5dGPAiEArTNvePFFy+53HcZffL4NKgVgPkhhEi8vy1JzmLB27OQ="

    // A different CA, standing in for the tunnel operator's publicly trusted
    // issuer.
    private static let foreignCADER = "MIIBgjCCASigAwIBAgIUbJN8Df6qM6xiNiOpKBhcxuQpeEEwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTdW5yZWxhdGVkIHB1YmxpYyBjYTAgFw0yNjA5MDUyMTU5MzNaGA8yMTI2MDgxMjIxNTkzM1owHjEcMBoGA1UEAwwTdW5yZWxhdGVkIHB1YmxpYyBjYTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABC+1gOHhzD/7KAdSuzW56p28YKtgpu3RT0qdNcJye+uqxSE69Us2lt82i9xEK1ELCj7HGFbo+w3ELAzuu2j7UWejQjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSFqnQbtFcq++nc/EPOSfZFXygLKDAKBggqhkjOPQQDAgNIADBFAiEA8n33Zk+pQV5m4BBTI7d/QJzClJf/nJOyAej2j8Dh25MCIBFAPVhqtwPCfTgT5pnOfDdCIrpVQe+mBZEG15jINtZb"

    // Leaf issued by the deployment CA with a conventional short lifetime.
    private static let hsproxyLeafDER = "MIIB3DCCAYGgAwIBAgIUKqlx2Rd58LSIONx24TDeKw5J1Q0wCgYIKoZIzj0EAwIwIjEgMB4GA1UEAwwXcmVwbHljYW50IGRlcGxveW1lbnQgY2EwHhcNMjYwOTA1MjIwNDMyWhcNMjcwNzAyMjIwNDMyWjAfMR0wGwYDVQQDDBRoc3Byb3h5LnRlc3QuZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJeP9moZTyWEl8cnyYiRf7dkiHbb7W3eEdGYJLQfvQbeXP/X91b+EuC0eYEunReojSZRu6rJr+dUjIa4HQDGud6jgZcwgZQwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHwYDVR0RBBgwFoIUaHNwcm94eS50ZXN0LmV4YW1wbGUwHQYDVR0OBBYEFOrhqNBAji9qi6xo61zopZqwFDnyMB8GA1UdIwQYMBaAFPxeQ8W19P0qsJmALwmx37YkhvfMMAoGCCqGSM49BAMCA0kAMEYCIQCR9WUxXyu0yTURF5f6GyDXBpPshZIRpIIczFn6VShZMAIhAMGoz6nD7+FnGU2yBLUZK1333xFo8kKnX8vIvRBd8QOM"

    // The same leaf reissued with the ten-year lifetime the compose stack
    // actually uses.
    private static let hsproxyLeafTenYearDER = "MIIB2zCCAYGgAwIBAgIUKqlx2Rd58LSIONx24TDeKw5J1Q4wCgYIKoZIzj0EAwIwIjEgMB4GA1UEAwwXcmVwbHljYW50IGRlcGxveW1lbnQgY2EwHhcNMjYwOTA1MjIwNDMyWhcNMzYwOTAyMjIwNDMyWjAfMR0wGwYDVQQDDBRoc3Byb3h5LnRlc3QuZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJeP9moZTyWEl8cnyYiRf7dkiHbb7W3eEdGYJLQfvQbeXP/X91b+EuC0eYEunReojSZRu6rJr+dUjIa4HQDGud6jgZcwgZQwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHwYDVR0RBBgwFoIUaHNwcm94eS50ZXN0LmV4YW1wbGUwHQYDVR0OBBYEFOrhqNBAji9qi6xo61zopZqwFDnyMB8GA1UdIwQYMBaAFPxeQ8W19P0qsJmALwmx37YkhvfMMAoGCCqGSM49BAMCA0gAMEUCIC2Acs9SAIlqsiiH6nmfMeVxFPMVDJr+o9Xzz59HSkS3AiEA6egWGUjdvEYYlrf+ijRVH27Cuf5RC95DwTcJhGZIY+M="

    // Leaf for the same hostname, issued by the foreign CA.
    private static let foreignLeafDER = "MIIB2TCCAX+gAwIBAgIUNjwBb4nMe8F2R46Rt3MiNDSTuOcwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTdW5yZWxhdGVkIHB1YmxpYyBjYTAgFw0yNjA5MDUyMTU5MzNaGA8yMTI2MDgxMjIxNTkzM1owHzEdMBsGA1UEAwwUaHNwcm94eS50ZXN0LmV4YW1wbGUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASGkEU6YPFlopV0mSKFya4xHc22sYcLlN5/JWsMx2JN/5grM7F4oYJQvYv5lBZ27m/1WdmMaLQj4TqOx0OZ+ZHao4GXMIGUMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMB8GA1UdEQQYMBaCFGhzcHJveHkudGVzdC5leGFtcGxlMB0GA1UdDgQWBBR4Wm0goY9Wr1jnih7qEy3SedWWNDAfBgNVHSMEGDAWgBSFqnQbtFcq++nc/EPOSfZFXygLKDAKBggqhkjOPQQDAgNIADBFAiBh8MbU0jcPIb/O9q0283H5RMhzrE5cuJfDzhHadoP9xwIhANCJralyO2Dyb6u65p2llrIj0e4bonB7OlunVk25RPdM"

    private static func certificate(_ base64DER: String) throws -> SecCertificate {
        let der = try #require(Data(base64Encoded: base64DER))
        return try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    // Builds the trust object Network framework would hand the verify block:
    // the chain the server presented, with no anchors yet decided.
    private static func presentedTrust(_ chain: [SecCertificate]) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            chain as CFArray,
            SecPolicyCreateBasicX509(),
            &trust
        )
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    // The working case. Without this passing, nothing else the test file
    // asserts distinguishes a correct pin from a blanket reject.
    @Test func acceptsALeafIssuedByThePinnedCA() throws {
        let ca = try Self.certificate(Self.deploymentCADER)
        let trust = try Self.presentedTrust([
            try Self.certificate(Self.hsproxyLeafDER),
            ca,
        ])

        #expect(HeadscaleControlShim.evaluate(trust: trust, pinnedCA: ca))
    }

    // The attack the pin exists for: a certificate from an issuer the device
    // never onboarded. It would satisfy an ordinary system-trust evaluation.
    @Test func rejectsAForeignlyIssuedLeaf() throws {
        let deploymentCA = try Self.certificate(Self.deploymentCADER)
        let trust = try Self.presentedTrust([
            try Self.certificate(Self.foreignLeafDER),
            try Self.certificate(Self.foreignCADER),
        ])

        #expect(HeadscaleControlShim.evaluate(trust: trust, pinnedCA: deploymentCA) == false)
    }

    // A leaf with nothing to chain to. Anchoring the pinned CA must not be
    // mistaken for having verified a signature by it.
    @Test func rejectsALeafPresentedWithoutItsIssuer() throws {
        let foreignCA = try Self.certificate(Self.foreignCADER)
        let foreignLeaf = try Self.certificate(Self.foreignLeafDER)
        let deploymentCA = try Self.certificate(Self.deploymentCADER)

        #expect(
            HeadscaleControlShim.evaluate(
                trust: try Self.presentedTrust([foreignLeaf]),
                pinnedCA: deploymentCA
            ) == false
        )
        // Guards against the fixture itself being the reason: the same leaf
        // does verify when its own issuer is the pin.
        #expect(
            HeadscaleControlShim.evaluate(
                trust: try Self.presentedTrust([foreignLeaf, foreignCA]),
                pinnedCA: foreignCA
            )
        )
    }

    // Regression guard for the reason this uses a basic X.509 policy rather
    // than `SecPolicyCreateSSL`. The SSL policy enforces Apple's 398-day
    // maximum lifetime even against a pinned anchor, so switching to it would
    // reject every certificate the compose stack issues, on every connection.
    @Test func acceptsTheTenYearLifetimeDeploymentsIssue() throws {
        let ca = try Self.certificate(Self.deploymentCADER)
        let trust = try Self.presentedTrust([
            try Self.certificate(Self.hsproxyLeafTenYearDER),
            ca,
        ])

        #expect(HeadscaleControlShim.evaluate(trust: trust, pinnedCA: ca))
    }

    private static func sha256Hex(_ base64DER: String) throws -> String {
        let der = try #require(Data(base64Encoded: base64DER))
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // A phone restoring from a recovery key holds only the CA's hash, and
    // hsproxy sends the CA after its leaf. The CA whose hash matches is the
    // one to trust, and the shim reports it so the app can pin it.
    @Test func picksTheCAMatchingTheRecoveryHashFromThePresentedChain() throws {
        let ca = try Self.certificate(Self.deploymentCADER)
        let trust = try Self.presentedTrust([
            try Self.certificate(Self.hsproxyLeafTenYearDER),
            ca,
        ])

        let verified = HeadscaleControlShim.evaluate(
            trust: trust,
            caSHA256: try Self.sha256Hex(Self.deploymentCADER).uppercased()
        )

        #expect(verified.map { SecCertificateCopyData($0) as Data }
            == (SecCertificateCopyData(ca) as Data))
    }

    // An impostor can present any CA it likes in its chain. Only the one the
    // recovery key names may be trusted, however valid the impostor's chain.
    @Test func rejectsAChainWhoseCADoesNotMatchTheRecoveryHash() throws {
        let trust = try Self.presentedTrust([
            try Self.certificate(Self.foreignLeafDER),
            try Self.certificate(Self.foreignCADER),
        ])

        #expect(HeadscaleControlShim.evaluate(
            trust: trust,
            caSHA256: try Self.sha256Hex(Self.deploymentCADER)
        ) == nil)
    }

    // The deployment CA is public, so an impostor can include it too. A match
    // by hash must still be followed by the leaf actually verifying against it.
    @Test func rejectsTheMatchingCAAlongsideALeafItDidNotIssue() throws {
        let trust = try Self.presentedTrust([
            try Self.certificate(Self.foreignLeafDER),
            try Self.certificate(Self.deploymentCADER),
        ])

        #expect(HeadscaleControlShim.evaluate(
            trust: trust,
            caSHA256: try Self.sha256Hex(Self.deploymentCADER)
        ) == nil)
    }
}
