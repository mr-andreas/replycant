import Foundation
import Testing

// Encapsulates host/container control endpoints so integration tests can run against real gitd safely.
//
// gitd publishes no host port, exactly as on a real deployment, so the suite
// reaches it the way the app does: through hsproxy and a tailnet node. Only
// the control plane, the first-device CA page and the harness's own control
// API are published to the host.
enum IntegrationEnvironment {
    // hsproxy as the simulator sees it. The container's server certificate
    // names localhost, so this verifies like a real deployment's hostname.
    static let headscaleURL = "https://localhost:18085"

    // The first-device page's payload: the CA, where headscale is, and a
    // single-use tailnet key. It is only served while the repository is
    // empty, which is what lets the first device join before it has a key
    // in pubkeys/.
    struct FirstDeviceConfig: Decodable {
        let ca: String
        let headscaleURL: String
        let preauthKey: String

        enum CodingKeys: String, CodingKey {
            case ca
            case headscaleURL = "headscale_url"
            case preauthKey = "preauth_key"
        }
    }

    // Carries provisioning-only identity material sent to the container control plane.
    struct ProvisionIdentity {
        let deviceName: String
        let deviceUUID: String
        let publicKeySSH: String
        let agePublicKey: String
    }

    // Marks suites as optional so day-to-day unit runs skip real-network integration scenarios.
    static var isEnabled: Bool {
        !(ProcessInfo.processInfo.environment["REPLYCANT_INTEGRATION_CTL"] ?? "").isEmpty
    }

    // Resolves the control endpoint configured by TEST_RUNNER_ environment forwarding.
    static func controlBaseURL() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["REPLYCANT_INTEGRATION_CTL"] ?? ""
        guard let url = URL(string: raw), !raw.isEmpty else {
            throw IntegrationEnvironmentError.missingControlURL
        }
        return url
    }

    // Resets container repository state between tests to avoid cross-test auth and history leakage.
    static func resetRepository(seed: Bool) async throws {
        struct ResetRequest: Encodable {
            let seed: Bool
        }
        _ = try await postJSON(path: "/reset", body: ResetRequest(seed: seed))
    }

    // Provisions one newly generated iOS identity into pubkeys and epoch envelopes.
    static func provision(identity: ProvisionIdentity) async throws {
        struct ProvisionRequest: Encodable {
            let deviceName: String
            let deviceUUID: String
            let publicKeySSH: String
            let agePublicKey: String
        }
        let request = ProvisionRequest(
            deviceName: identity.deviceName,
            deviceUUID: identity.deviceUUID,
            publicKeySSH: identity.publicKeySSH,
            agePublicKey: identity.agePublicKey
        )
        _ = try await postJSON(path: "/provision", body: request)
    }

    // Appends deterministic media commits for sync/database verification cases.
    static func seedMedia(mediaCount: Int, commitCount: Int, deviceSpace: String) async throws {
        struct SeedRequest: Encodable {
            let mediaCount: Int
            let commitCount: Int
            let deviceSpace: String
        }
        let request = SeedRequest(mediaCount: mediaCount, commitCount: commitCount, deviceSpace: deviceSpace)
        _ = try await postJSON(path: "/seed", body: request)
    }

    // The CA the container minted at startup. A paired device would have
    // received it in its pairing record; the harness skips pairing and asks.
    static func harnessCA() async throws -> String {
        let url = try controlBaseURL().appendingPathComponent("ca")
        let data = try await get(url, what: "harness CA")
        guard let pem = String(data: data, encoding: .utf8), pem.contains("BEGIN CERTIFICATE") else {
            throw IntegrationEnvironmentError.invalidResponse("harness CA is not a PEM certificate")
        }
        return pem
    }

    // Reads the same payload the first-device QR encodes.
    static func firstDeviceConfig() async throws -> FirstDeviceConfig {
        guard let url = URL(string: "http://localhost:18080/config.json") else {
            throw IntegrationEnvironmentError.invalidURL
        }
        let data = try await get(url, what: "first-device config")
        do {
            return try JSONDecoder().decode(FirstDeviceConfig.self, from: data)
        } catch {
            throw IntegrationEnvironmentError.invalidResponse("first-device config decode failed: \(error)")
        }
    }

    private static func get(_ url: URL, what: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntegrationEnvironmentError.invalidResponse("\(what) returned non-http response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw IntegrationEnvironmentError.invalidResponse("\(what) returned status \(httpResponse.statusCode)")
        }
        return data
    }

    // Sends a control-plane JSON command and validates common error response contracts.
    private static func postJSON<T: Encodable>(path: String, body: T) async throws -> Data {
        let baseURL = try controlBaseURL()
        let endpoint = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntegrationEnvironmentError.invalidResponse("control response was not http")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw IntegrationEnvironmentError.controlRequestFailed(
                status: httpResponse.statusCode,
                payload: payload
            )
        }
        return data
    }
}

// Reports integration-control and discovery failures with specific remediation hints for local runs.
enum IntegrationEnvironmentError: Error, CustomStringConvertible {
    case missingControlURL
    case invalidURL
    case invalidResponse(String)
    case controlRequestFailed(status: Int, payload: String)

    // Summarizes failure context for test output readability when docker stack setup breaks.
    var description: String {
        switch self {
        case .missingControlURL:
            return "REPLYCANT_INTEGRATION_CTL is missing; run make ios-integration-test"
        case .invalidURL:
            return "integration endpoint URL is invalid"
        case .invalidResponse(let message):
            return message
        case .controlRequestFailed(let status, let payload):
            return "control request failed with status \(status): \(payload)"
        }
    }
}
