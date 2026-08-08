import Foundation
import Testing

// Encapsulates host/container control endpoints so integration tests can run against real gitd safely.
enum IntegrationEnvironment {
    // Captures caserver discovery payload shared by app onboarding and integration harness setup.
    struct DiscoveryConfig: Decodable {
        let ca: String
        let url: String
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

    // Reads the same caserver config payload consumed by onboarding QR flows.
    static func discoverConfig() async throws -> DiscoveryConfig {
        guard let url = URL(string: "http://localhost:18080/config.json") else {
            throw IntegrationEnvironmentError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntegrationEnvironmentError.invalidResponse("discover config returned non-http response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw IntegrationEnvironmentError.invalidResponse("discover config returned status \(httpResponse.statusCode)")
        }
        do {
            return try JSONDecoder().decode(DiscoveryConfig.self, from: data)
        } catch {
            throw IntegrationEnvironmentError.invalidResponse("discover config decode failed: \(error)")
        }
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
