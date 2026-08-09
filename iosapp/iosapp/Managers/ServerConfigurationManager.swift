import Foundation
import CryptoKit
import Security

// Stores and manages server configuration obtained from QR code scanning.
// Provides CA certificate pinning and URL persistence for mTLS Git connections.
final class ServerConfigurationManager {
    
    // Singleton instance for app-wide server configuration.
    static let shared = ServerConfigurationManager()
    // Broadcasts derived LFS endpoint changes so long-lived managers can rebuild LFS clients.
    static let lfsURLDidChangeNotification = Notification.Name("ServerConfigurationManager.lfsURLDidChange")
    
    private let keychainService = "com.replycant.iosapp.server"
    private let caAccountKey = "ca-certificate"
    private let urlKey = "gitServerURL"
    
    private init() {}
    
    // MARK: - Configuration Model
    
    // Server configuration parsed from QR code JSON.
    struct Configuration: Codable {
        let url: String
        let caCertificate: String
        
        // Returns the server URL as a URL object.
        var serverURL: URL? {
            URL(string: url)
        }
    }
    
    // MARK: - Public Interface
    
    // Checks if a server configuration exists.
    var isConfigured: Bool {
        return loadURL() != nil && loadCACertificate() != nil
    }
    
    // Parses QR code JSON data and stores the configuration.
    // Expected format: {"ca": "<PEM certificate>", "url": "<server URL>"}
    func configure(fromQRCodeData jsonData: Data) throws {
        log("Parsing QR code data (\(jsonData.count) bytes)", context: "ServerConfig")
        
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String],
              let ca = json["ca"],
              let url = json["url"] else {
            throw ConfigurationError.invalidQRCodeFormat
        }
        
        try configure(url: url, caCertificate: ca)
    }
    
    // Parses QR code JSON string and stores the configuration.
    func configure(fromQRCodeString jsonString: String) throws {
        guard let data = jsonString.data(using: .utf8) else {
            throw ConfigurationError.invalidQRCodeFormat
        }
        try configure(fromQRCodeData: data)
    }

    // Resolves discovery JSON and verifies the CA fingerprint before persisting trust configuration.
    // This lets recovery re-target moved servers while keeping the original out-of-band trust anchor.
    func discoverAndConfigure(
        discoveryURLString: String,
        expectedCAHash: String,
        session: URLSession = .shared
    ) async throws -> Configuration {
        guard let configURL = Self.discoveryConfigURL(from: discoveryURLString) else {
            throw ConfigurationError.invalidDiscoveryURL
        }

        let responseData: Data
        do {
            let (data, response) = try await session.data(from: configURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode else {
                throw ConfigurationError.discoveryFetchFailed
            }
            responseData = data
        } catch {
            throw ConfigurationError.discoveryFetchFailed
        }

        guard let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: String],
              let discoveredCA = payload["ca"],
              let discoveredURL = payload["url"] else {
            throw ConfigurationError.invalidDiscoveryResponse
        }

        guard let discoveredHash = Self.certificateHash(fromPEM: discoveredCA),
              discoveredHash.caseInsensitiveCompare(expectedCAHash) == .orderedSame else {
            throw ConfigurationError.discoveryCAHashMismatch
        }

        try configure(url: discoveredURL, caCertificate: discoveredCA)
        return Configuration(url: discoveredURL, caCertificate: discoveredCA)
    }
    
    // Stores the server URL and CA certificate, from which LFS URL is always derived.
    func configure(url: String, caCertificate: String) throws {
        log("Configuring server URL: \(url)", context: "ServerConfig")
        
        guard URL(string: url) != nil else {
            throw ConfigurationError.invalidURL
        }
        
        guard caCertificate.contains("-----BEGIN CERTIFICATE-----") else {
            throw ConfigurationError.invalidCertificate
        }
        
        try storeURL(url)
        try storeCACertificate(caCertificate)
        
        log("Configuration saved successfully", context: "ServerConfig")
    }

    // Applies optional local simulator endpoints and CA when present so debug launches can skip QR onboarding.
    // The CA and optional git-url are never shipped in-repo; developers place
    // them under SimulatorCredentials/ locally.
    func applyBundledSimulatorConfigurationIfNeeded() throws {
        #if DEBUG && targetEnvironment(simulator)
        if isConfigured {
            log("Server configuration already present, skipping simulator defaults", context: "ServerConfig")
            return
        }

        guard let caPEM = loadBundledCredential(named: "ca", ext: "crt") else {
            log("No local simulator CA bundled; skipping server defaults", context: "ServerConfig")
            return
        }

        try configure(
            url: Self.resolveSimulatorGitURL(
                bundledGitURL: loadBundledCredential(named: "git-url", ext: nil)
            ),
            caCertificate: caPEM
        )
        #endif
    }

    // Prefers a local SimulatorCredentials/git-url so debug launches can
    // follow a remapped gitd port without changing compiled defaults.
    static func resolveSimulatorGitURL(bundledGitURL: String?) -> String {
        let trimmed = bundledGitURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "https://replycant.local:8443"
        }
        return trimmed
    }
    
    // Returns the current configuration if available.
    func loadConfiguration() -> Configuration? {
        guard let url = loadURL(),
              let ca = loadCACertificate() else {
            return nil
        }
        return Configuration(url: url, caCertificate: ca)
    }
    
    // Returns the server URL.
    func loadURL() -> String? {
        return UserDefaults.standard.string(forKey: urlKey)
    }

    // Allows updating just the Git server URL when users repoint an existing local repo to a different origin.
    // This keeps GitHTTPClient aligned with the repo’s configured remote without requiring a full QR re-onboarding.
    func updateServerURL(_ url: String) throws {
        guard URL(string: url) != nil else {
            throw ConfigurationError.invalidURL
        }
        try storeURL(url)
        NotificationCenter.default.post(
            name: Self.lfsURLDidChangeNotification,
            object: nil,
            userInfo: ["lfsURL": Self.deriveLFSURL(from: url) ?? ""]
        )
    }
    
    // Returns the LFS server URL.
    func loadLFSURL() -> String? {
        guard let gitURL = loadURL() else {
            return nil
        }
        return Self.deriveLFSURL(from: gitURL)
    }

    // Derives the LFS endpoint from the git server URL so client protocols share one origin.
    static func deriveLFSURL(from gitURLString: String) -> String? {
        deriveServiceURL(from: gitURLString, path: "/lfs")
    }

    // Derives a backend service endpoint from the git server URL.
    //
    // gitd proxies every backend service (LFS, decryptd, transcoded) under its
    // own path prefix, and those services publish no host ports of their own.
    // Reusing the git origin is therefore what puts each service behind the same
    // mTLS-authenticated endpoint the device already trusts.
    static func deriveServiceURL(from gitURLString: String, path: String) -> String? {
        guard let gitURL = URL(string: gitURLString),
              let scheme = gitURL.scheme,
              let host = gitURL.host else {
            return nil
        }

        // Maps libgit2's custom transport scheme back to HTTPS for URLSession calls.
        let normalizedScheme = scheme == "mtls+https" ? "https" : scheme

        var components = URLComponents()
        components.scheme = normalizedScheme
        components.host = host
        components.port = gitURL.port
        components.path = path
        return components.url?.absoluteString
    }
    
    // Returns the CA certificate in PEM format.
    func loadCACertificate() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: caAccountKey,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let pem = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return pem
    }

    // Produces a deterministic hash of the pinned CA certificate so device-link QR verification can detect server mismatches.
    func caCertificateHash() -> String? {
        guard let pem = loadCACertificate() else {
            return nil
        }
        return Self.certificateHash(fromPEM: pem)
    }
    
    // Returns the CA certificate as SecCertificate for trust evaluation.
    func loadSecCertificate() -> SecCertificate? {
        guard let pem = loadCACertificate() else {
            return nil
        }

        guard let derData = Self.decodeCertificateDER(fromPEM: pem) else {
            logError("Failed to decode CA certificate base64", context: "ServerConfig")
            return nil
        }
        
        guard let certificate = SecCertificateCreateWithData(nil, derData as CFData) else {
            logError("Failed to create SecCertificate", context: "ServerConfig")
            return nil
        }
        
        return certificate
    }
    
    // Clears the stored configuration.
    func clearConfiguration() {
        UserDefaults.standard.removeObject(forKey: urlKey)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: caAccountKey
        ]
        SecItemDelete(query as CFDictionary)
        
        log("Configuration cleared", context: "ServerConfig")
    }
    
    // MARK: - Private Storage
    
    private func storeURL(_ url: String) throws {
        UserDefaults.standard.set(url, forKey: urlKey)
    }
    
    private func storeCACertificate(_ pem: String) throws {
        guard let data = pem.data(using: .utf8) else {
            throw ConfigurationError.invalidCertificate
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: caAccountKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        // Delete existing entry first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logError("Failed to store CA certificate: \(status)", context: "ServerConfig")
            throw ConfigurationError.keychainError(status)
        }
    }

    // Reads optional local simulator CA or git-url files from the app bundle
    // when present so debug launches can skip QR onboarding.
    private func loadBundledCredential(named name: String, ext: String?) -> String? {
        let subdirectories: [String?] = ["SimulatorCredentials", "Resources/SimulatorCredentials", nil]

        for subdirectory in subdirectories {
            let resourceURL: URL?
            if let subdirectory {
                resourceURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            } else {
                resourceURL = Bundle.main.url(forResource: name, withExtension: ext)
            }

            if let resourceURL,
               let content = try? String(contentsOf: resourceURL, encoding: .utf8) {
                return content
            }
        }

        return nil
    }

    // Decodes certificate PEM into canonical DER bytes so trust and hash logic share one normalization path.
    private static func decodeCertificateDER(fromPEM pem: String) -> Data? {
        let lines = pem.components(separatedBy: "\n")
        var base64 = ""
        var inCertificate = false

        for line in lines {
            if line.contains("-----BEGIN CERTIFICATE-----") {
                inCertificate = true
                continue
            }
            if line.contains("-----END CERTIFICATE-----") {
                break
            }
            if inCertificate {
                base64 += line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !base64.isEmpty else {
            return nil
        }
        return Data(base64Encoded: base64)
    }

    // Computes lowercase SHA256 hex for a certificate PEM so webapp authorization can compare CA identity.
    static func certificateHash(fromPEM pem: String) -> String? {
        guard let derData = decodeCertificateDER(fromPEM: pem) else {
            return nil
        }
        let digest = SHA256.hash(data: derData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // Normalizes operator-provided discovery URLs into a concrete config.json endpoint.
    // Recovery asks users for a discovery address when the original endpoint is unreachable.
    static func discoveryConfigURL(from discoveryURLString: String) -> URL? {
        let trimmed = discoveryURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        switch path {
        case "", "/":
            components.path = "/config.json"
        case "/config.json":
            break
        default:
            components.path = path.hasSuffix("/") ? path + "config.json" : path + "/config.json"
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

// Errors that can occur during server configuration.
enum ConfigurationError: Error, LocalizedError {
    case invalidQRCodeFormat
    case invalidURL
    case invalidCertificate
    case keychainError(OSStatus)
    case invalidDiscoveryURL
    case discoveryFetchFailed
    case invalidDiscoveryResponse
    case discoveryCAHashMismatch
    
    var errorDescription: String? {
        switch self {
        case .invalidQRCodeFormat:
            return "Invalid QR code format. Expected JSON with 'ca' and 'url' fields."
        case .invalidURL:
            return "Invalid server URL"
        case .invalidCertificate:
            return "Invalid CA certificate"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .invalidDiscoveryURL:
            return "Invalid discovery URL. Expected an http(s) URL to the gitd discovery endpoint."
        case .discoveryFetchFailed:
            return "Could not reach discovery server."
        case .invalidDiscoveryResponse:
            return "Discovery server returned invalid configuration."
        case .discoveryCAHashMismatch:
            return "Discovery server CA did not match the pinned recovery key fingerprint."
        }
    }
}

