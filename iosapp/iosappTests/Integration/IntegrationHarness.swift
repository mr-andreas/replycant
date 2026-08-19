import Foundation
import LibGit2
@testable import iosapp

// Prepares deterministic app, keychain, and repository state for real gitd integration tests.
@MainActor
enum IntegrationHarness {
    // Captures transport and discovery details needed by tests after one harness preparation step.
    struct PreparedContext {
        let discovery: IntegrationEnvironment.DiscoveryConfig
        let provisionIdentity: IntegrationEnvironment.ProvisionIdentity
        let repositoryPath: String

        // Exposes the mtls remote URL expected by libgit2 transport registration.
        var mtlsRemoteURL: String {
            MTLSTransport.convertToMTLSScheme(discovery.url)
        }
    }

    // Sets up a seeded repo and authorized device identity for clone/sync/LFS integration paths.
    static func prepareSeededAndProvisioned() async throws -> PreparedContext {
        try await prepare(seedContainerRepo: true, provisionDevice: true)
    }

    // Sets up an empty bootstrap repo so tests can validate first-device push behavior.
    static func prepareUnseededBootstrap() async throws -> PreparedContext {
        try await prepare(seedContainerRepo: false, provisionDevice: false)
    }

    // Sets up a seeded repo without provisioning so auth-deny tests can verify unauthorized push behavior.
    static func prepareSeededWithoutProvisioning() async throws -> PreparedContext {
        try await prepare(seedContainerRepo: true, provisionDevice: false)
    }

    // Resets app-local state so integration tests can emulate uninstall/reinstall before recovery.
    static func resetLocalInstallState() async throws {
        try await wipeLocalState()
    }

    // Creates one unique path under tmp for isolated repositories used in failing-auth push tests.
    static func makeTemporaryRepositoryPath(prefix: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .path
    }

    // Clones the integration remote into the app repository path and aligns singleton caches to that clone.
    static func cloneIntoManagedRepository(from remoteURL: String) throws -> Repository {
        let path = RepositoryManager.shared.repositoryPath()
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        let repository = try Repository.clone(from: remoteURL, to: path)
        RepositoryManager.shared.clearRepository()
        RepositoryManager.shared.cacheRepositoryForTesting(repository)
        GitDBManager.shared.clearGitDB()
        return repository
    }

    // Clears app caches and filesystem state so each integration test starts as a fresh install.
    private static func wipeLocalState() async throws {
        RepositoryManager.shared.clearRepository()
        GitDBManager.shared.clearGitDB()
        try await ManifestLoaderManager.shared.deleteDatabaseFile()
        let repoPath = RepositoryManager.shared.repositoryPath()
        if FileManager.default.fileExists(atPath: repoPath) {
            try FileManager.default.removeItem(atPath: repoPath)
        }
        ServerConfigurationManager.shared.clearConfiguration()
        try ClientIdentityManager.shared.resetIdentityForTesting()
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    }

    // Prepares repository control state, onboarding config, and mTLS credentials for one test scenario.
    private static func prepare(seedContainerRepo: Bool, provisionDevice: Bool) async throws -> PreparedContext {
        try await wipeLocalState()
        try await IntegrationEnvironment.resetRepository(seed: seedContainerRepo)
        let discovery = try await IntegrationEnvironment.discoverConfig()
        try ServerConfigurationManager.shared.configure(url: discovery.url, caCertificate: discovery.ca)

        let provisionIdentity = try generateProvisionIdentity()
        try configureTransportFromStoredIdentity()

        if provisionDevice {
            try await IntegrationEnvironment.provision(identity: provisionIdentity)
        }

        return PreparedContext(
            discovery: discovery,
            provisionIdentity: provisionIdentity,
            repositoryPath: RepositoryManager.shared.repositoryPath()
        )
    }

    // Generates a fresh client identity and public onboarding payload used by the container provisioner.
    private static func generateProvisionIdentity() throws -> IntegrationEnvironment.ProvisionIdentity {
        let deviceName = "ios-integration-device"
        let deviceUUID = UUID().uuidString.lowercased()
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: deviceName)
        let publicKeySSH = try ClientIdentityManager.shared.sshPublicKey(comment: "\(deviceName)-\(deviceUUID)")
        let agePublicKey = try ClientIdentityManager.shared.agePublicKey()
        return IntegrationEnvironment.ProvisionIdentity(
            deviceName: deviceName,
            deviceUUID: deviceUUID,
            publicKeySSH: publicKeySSH,
            agePublicKey: agePublicKey
        )
    }

    // Configures libgit2's custom transport from currently stored keychain identity and pinned CA.
    private static func configureTransportFromStoredIdentity() throws {
        guard let identity = ClientIdentityManager.shared.loadSecIdentity() else {
            throw IntegrationHarnessError.missingClientIdentity
        }
        guard let pinnedCA = ServerConfigurationManager.shared.loadSecCertificate() else {
            throw IntegrationHarnessError.missingPinnedCA
        }
        try MTLSTransport.shared.configure(clientIdentity: identity, pinnedCA: pinnedCA)
    }
}

// Surfaces harness setup failures that indicate local keychain or discovery setup problems.
enum IntegrationHarnessError: Error, CustomStringConvertible {
    case missingClientIdentity
    case missingPinnedCA

    // Produces concise diagnostics for quickly fixing local integration environment issues.
    var description: String {
        switch self {
        case .missingClientIdentity:
            return "client identity is missing after generation"
        case .missingPinnedCA:
            return "pinned CA is missing after discovery configuration"
        }
    }
}
