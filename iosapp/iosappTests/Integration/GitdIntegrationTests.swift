import Foundation
import Testing
import LibGit2
import GitDB
@testable import iosapp

// Verifies iOS git/LFS/GitDB workflows against the real dockerized gitd integration stack.
@MainActor
@Suite(.serialized, .enabled(if: IntegrationEnvironment.isEnabled))
struct GitdIntegrationTests {
    // Bootstraps first-device repository metadata and pushes it to an empty integration remote.
    private func bootstrapRepository(
        remoteURL: String,
        identity: IntegrationEnvironment.ProvisionIdentity
    ) throws -> Repository {
        let repoPath = RepositoryManager.shared.repositoryPath()
        if FileManager.default.fileExists(atPath: repoPath) {
            try FileManager.default.removeItem(atPath: repoPath)
        }
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        let keyManager = KEKEpochManager(repository: repository)
        var files = try keyManager.bootstrapFilesForFirstEpoch(
            recipientAgePubkeys: [identity.agePublicKey]
        )
        let base = "\(identity.deviceName)-\(identity.deviceUUID)"
        files.append((path: "pubkeys/\(base).pub", content: identity.publicKeySSH + "\n"))
        files.append((path: "pubkeys/\(base).age", content: identity.agePublicKey + "\n"))
        try repository.createCommit(message: "bootstrap iOS integration identity", files: files)
        try repository.addRemote(name: "origin", url: remoteURL)
        try repository.push(remoteName: "origin", branchName: "main")
        RepositoryManager.shared.cacheRepositoryForTesting(repository)
        return repository
    }

    // Confirms first-device bootstrap push works against a completely empty real gitd repo.
    @Test
    func bootstrapPushAndReclone() async throws {
        let context = try await IntegrationHarness.prepareUnseededBootstrap()
        _ = try bootstrapRepository(
            remoteURL: context.mtlsRemoteURL,
            identity: context.provisionIdentity
        )
        let recloned = try IntegrationHarness.cloneIntoManagedRepository(from: context.mtlsRemoteURL)
        #expect(recloned.fileExists(at: "encryption/current"))
        #expect(
            recloned.fileExists(
                at: "pubkeys/\(context.provisionIdentity.deviceName)-\(context.provisionIdentity.deviceUUID).pub"
            )
        )
    }

    // Confirms seeded-repo provisioning allows clone and KEK epoch decryption on iOS.
    @Test
    func provisionCloneAndDecryptEpoch() async throws {
        let context = try await IntegrationHarness.prepareSeededAndProvisioned()
        let repository = try IntegrationHarness.cloneIntoManagedRepository(from: context.mtlsRemoteURL)
        let keyManager = KEKEpochManager(repository: repository)
        let kek = try keyManager.loadKEK(epoch: 1)
        #expect(!kek.isEmpty)
        // The Go seeder writes the envelope body as raw AES-GCM bytes rather than
        // base64, so the blob is read as Data instead of a UTF-8 string.
        let headOID = try #require(repository.headOID())
        let seedBlob = try repository.readBlobDataAtCommit(
            commitOid: headOID,
            filepath: "manifests/test/test.yaml"
        )
        let seedManifest = try #require(seedBlob)
        #expect(seedManifest.starts(with: Data("REPLYCANT-ENC-V1\n".utf8)))
    }

    // Confirms seeded media history sync populates GitDB-backed manifest SQL tables.
    @Test
    func syncRoundTripHydratesGitDB() async throws {
        let context = try await IntegrationHarness.prepareSeededAndProvisioned()
        let deviceSpace = "ios-integration-device"
        try await IntegrationEnvironment.seedMedia(mediaCount: 12, commitCount: 3, deviceSpace: deviceSpace)
        _ = try IntegrationHarness.cloneIntoManagedRepository(from: context.mtlsRemoteURL)

        GitDBManager.shared.clearGitDB()
        let gitDB = try GitDBManager.shared.getGitDB()
        try await gitDB.syncToHead(progressHandler: nil)

        let tableName = try await gitDB.tableName(for: OriginalManifest.self)
        let count = try await gitDB.queryCount(
            sql: "SELECT COUNT(*) FROM \(tableName) WHERE deviceSpace = ? AND takenAt IS NOT NULL",
            arguments: [deviceSpace]
        )
        #expect(count > 0)
    }

    // Confirms real gitd LFS proxy accepts mTLS uploads and returns identical object payloads.
    @Test
    func lfsUploadDownloadRoundTrip() async throws {
        _ = try await IntegrationHarness.prepareSeededAndProvisioned()
        let lfsURL = try #require(ServerConfigurationManager.shared.loadLFSURL())
        let identity = try #require(ClientIdentityManager.shared.loadSecIdentity())
        let pinnedCA = try #require(ServerConfigurationManager.shared.loadSecCertificate())
        let lfsClient = GitLFS(serverURL: lfsURL, clientIdentity: identity, pinnedCA: pinnedCA)
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let pointer = try await lfsClient.uploadData(payload)
        let downloaded = try await lfsClient.downloadData(oid: pointer.oid, size: pointer.size)
        #expect(downloaded == payload)
    }

    // Confirms seeded repos reject push attempts from identities that were never provisioned.
    @Test
    func unauthorizedPushRejected() async throws {
        let context = try await IntegrationHarness.prepareSeededWithoutProvisioning()
        let repoPath = IntegrationHarness.makeTemporaryRepositoryPath(prefix: "ios-unauthorized-push")
        defer { try? FileManager.default.removeItem(atPath: repoPath) }
        let repository = try Repository.create(at: repoPath, bare: false)
        try repository.createCommit(
            message: "unauthorized push attempt",
            files: [(path: "unauthorized.txt", content: "blocked")]
        )
        try repository.addRemote(name: "origin", url: context.mtlsRemoteURL)

        do {
            try repository.push(remoteName: "origin", branchName: "main")
            Issue.record("push unexpectedly succeeded without provisioning")
        } catch {
            let message = String(describing: error).lowercased()
            let expectedAuthFailure =
                message.contains("unauthorized") ||
                message.contains("public key not authorized") ||
                message.contains("auth") ||
                message.contains("401")
            #expect(expectedAuthFailure)
        }
    }

    // Confirms creating a recovery key writes marked key files to the integration remote.
    @Test
    func recoveryKeyCreationPublishesMarkedPubkeys() async throws {
        let context = try await IntegrationHarness.prepareSeededAndProvisioned()
        let repository = try IntegrationHarness.cloneIntoManagedRepository(from: context.mtlsRemoteURL)
        let gitDB = try GitDBManager.shared.getGitDB()
        let config = try #require(ServerConfigurationManager.shared.loadConfiguration())
        let manager = RecoveryKeyManager()
        let created = try await manager.createRecoveryKey(
            label: "integration-recovery",
            password: "correct horse battery staple",
            repository: repository,
            gitDB: gitDB,
            serverConfiguration: config
        )

        let recloned = try IntegrationHarness.cloneIntoManagedRepository(from: context.mtlsRemoteURL)
        #expect(recloned.fileExists(at: created.recoveryPubPath))
        #expect(recloned.fileExists(at: created.recoveryAgePath))
    }

    // Confirms wrong recovery passwords fail closed before any network mutation.
    @Test
    func recoveryWithWrongPasswordFails() async throws {
        let context = try await IntegrationHarness.prepareSeededAndProvisioned()
        let repository = try IntegrationHarness.cloneIntoManagedRepository(from: context.mtlsRemoteURL)
        let gitDB = try GitDBManager.shared.getGitDB()
        let config = try #require(ServerConfigurationManager.shared.loadConfiguration())
        let manager = RecoveryKeyManager()
        let created = try await manager.createRecoveryKey(
            label: "wrong-password-recovery",
            password: "correct horse battery staple",
            repository: repository,
            gitDB: gitDB,
            serverConfiguration: config
        )

        do {
            _ = try await manager.recover(input: created.deepLink, password: "definitely-wrong")
            Issue.record("recovery unexpectedly succeeded with wrong password")
        } catch RecoveryBundle.Error.wrongPassword {
            // Expected: decrypt maps GCM auth failure to a typed password error.
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // Confirms recovery is blocked on already-configured installs to enforce reinstall guidance.
    @Test
    func recoveryRejectedWhenDeviceAlreadyConfigured() async throws {
        _ = try await IntegrationHarness.prepareSeededAndProvisioned()
        let manager = RecoveryKeyManager()

        do {
            _ = try await manager.recover(input: "replycant://recover?v=1&d=bogus", password: "x")
            Issue.record("recovery unexpectedly bypassed configured-device gate")
        } catch {
            guard case RecoveryKeyManager.Error.alreadyConfiguredDevice = error else {
                Issue.record("expected alreadyConfiguredDevice error, got \(error)")
                return
            }
        }
    }

    // Confirms recovery can re-enroll a wiped install and pushes a new non-recovery device key.
    @Test
    func recoveryAfterWipeRegistersNewDeviceKey() async throws {
        let context = try await IntegrationHarness.prepareSeededAndProvisioned()
        let repository = try IntegrationHarness.cloneIntoManagedRepository(from: context.mtlsRemoteURL)
        let gitDB = try GitDBManager.shared.getGitDB()
        let config = try #require(ServerConfigurationManager.shared.loadConfiguration())
        let manager = RecoveryKeyManager()
        let created = try await manager.createRecoveryKey(
            label: "wipe-recover",
            password: "correct horse battery staple",
            repository: repository,
            gitDB: gitDB,
            serverConfiguration: config
        )

        let beforePubCount = try repository
            .listFiles(in: "pubkeys")
            .filter { $0.hasSuffix(".pub") && !$0.contains(".recovery.") }
            .count

        try IntegrationHarness.resetLocalInstallState()
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "ios-recovered-device")

        _ = try await manager.recover(input: created.deepLink, password: "correct horse battery staple")

        let recoveredRepository = try IntegrationHarness.cloneIntoManagedRepository(from: context.mtlsRemoteURL)
        let afterPubCount = try recoveredRepository
            .listFiles(in: "pubkeys")
            .filter { $0.hasSuffix(".pub") && !$0.contains(".recovery.") }
            .count
        #expect(afterPubCount > beforePubCount)
    }
}
