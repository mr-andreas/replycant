import Foundation
import LibGit2
@testable import iosapp

// Prepares deterministic app, keychain, and repository state for real gitd integration tests.
@MainActor
enum IntegrationHarness {
    // Captures the identity and paths tests need after one harness preparation step.
    struct PreparedContext {
        let provisionIdentity: IntegrationEnvironment.ProvisionIdentity
        let repositoryPath: String

        // gitd's tailnet name in the scheme libgit2's transport is registered
        // for. It only resolves through the node the harness joined.
        var mtlsRemoteURL: String {
            MTLSTransport.convertToMTLSScheme(TailnetConfiguration.gitdURL)
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

    // Sets up a seeded repo without provisioning, and without joining, so
    // tests can check that an unknown device is kept off the tailnet.
    static func prepareSeededWithoutProvisioning() async throws -> PreparedContext {
        try await prepare(seedContainerRepo: true, provisionDevice: false)
    }

    // Resets app-local state so integration tests can emulate uninstall/reinstall before recovery.
    static func resetLocalInstallState() async throws {
        try await wipeLocalState()
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
    //
    // The tailnet node's state goes too. Each test resets pubkeys/, so a node
    // kept from the previous test would belong to a key gitd has just revoked.
    private static func wipeLocalState() async throws {
        await TailnetBootstrap.shared.leave()
        let tailnetState = TailnetBootstrap.stateDirectory
        if FileManager.default.fileExists(atPath: tailnetState.path) {
            try FileManager.default.removeItem(at: tailnetState)
        }
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

    // Prepares repository control state, server trust, mTLS credentials, and
    // tailnet membership for one test scenario.
    //
    // A provisioned device mints its own tailnet key through hsproxy, as a
    // paired device does once its key is on main. The first device has no
    // key to mint with yet, so it takes the CA page's single-use key instead.
    private static func prepare(seedContainerRepo: Bool, provisionDevice: Bool) async throws -> PreparedContext {
        try await wipeLocalState()
        try await IntegrationEnvironment.resetRepository(seed: seedContainerRepo)

        let firstDevice = seedContainerRepo ? nil : try await IntegrationEnvironment.firstDeviceConfig()
        let ca: String
        if let firstDevice {
            ca = firstDevice.ca
        } else {
            ca = try await IntegrationEnvironment.harnessCA()
        }
        try ServerConfigurationManager.shared.configure(url: TailnetConfiguration.gitdURL, caCertificate: ca)

        let provisionIdentity = try generateProvisionIdentity()
        try configureTransportFromStoredIdentity()

        if provisionDevice {
            try await IntegrationEnvironment.provision(identity: provisionIdentity)
        }
        if let firstDevice {
            try await TailnetBootstrap.shared.joinAndPersist(
                headscaleURL: firstDevice.headscaleURL,
                preauthKey: firstDevice.preauthKey
            )
        } else if provisionDevice {
            try await TailnetBootstrap.shared.joinAndPersist(
                headscaleURL: IntegrationEnvironment.headscaleURL,
                preauthKey: nil
            )
        }

        return PreparedContext(
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
            return "pinned CA is missing after server trust configuration"
        }
    }
}
