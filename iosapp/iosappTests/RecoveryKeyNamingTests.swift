import Foundation
import GitDB
import LibGit2
import Testing
@testable import iosapp

// Verifies recovery key filename conventions so auth and encryption recipient scans keep working.
struct RecoveryKeyNamingTests {
    // Recovery keys are key sets with type recovery. A device key set
    // and a file that does not parse are not recovery keys.
    @Test func listRecoveryKeysReturnsRecoveryKeySets() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("recovery-naming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let repo = try Repository.create(at: root, bare: false)
        let validUUID = UUID().uuidString.lowercased()
        let validName = "home-safe-primary-\(validUUID)"
        let device = try keySetFile(name: "device-main", type: KeySet.typeDevice)
        let recovery = try keySetFile(name: validName, type: KeySet.typeRecovery)
        try repo.createCommit(
            message: "seed recovery key sets",
            files: [
                recovery,
                device,
                (path: "pubkeys/notes.yaml", content: "not a key set\n"),
            ]
        )

        let records = try RecoveryKeyManager().listRecoveryKeys(repository: repo)
        #expect(records.count == 1)
        #expect(records[0].label == validName)
        #expect(records[0].uuid == validUUID)
        #expect(records[0].path == recovery.path)
    }

    // Confirms create/delete broadcasts so Settings can drop the recovery
    // warning without waiting for the next app launch.
    @Test func postRecoveryKeysDidChangePostsNotification() async {
        let center = NotificationCenter()
        let stream = center.notifications(named: .recoveryKeysDidChange)
        let waiter = Task {
            for await _ in stream {
                return true
            }
            return false
        }

        RecoveryKeyManager.postRecoveryKeysDidChange(to: center)
        let didReceive = await waiter.value
        #expect(didReceive)
    }

    // Coordinates lock-acquired timing so delete cannot race an in-flight mutation.
    private actor MutationLockAcquireSignal {
        private var isAcquired = false
        private var continuation: CheckedContinuation<Void, Never>?

        // Marks that the holder entered the critical section before delete starts.
        func markAcquired() {
            isAcquired = true
            continuation?.resume()
            continuation = nil
        }

        // Waits until the holder confirms lock ownership.
        func waitUntilAcquired() async {
            if isAcquired {
                return
            }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    // Verifies deleteRecoveryKey waits for an in-flight mutation so its
    // follow-up push cannot interleave with a periodic rebase.
    @Test func testDeleteRecoveryKeyWaitsForMutationLock() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("recovery-delete-lock-\(UUID().uuidString)")
        let remotePath = (root as NSString).appendingPathComponent("remote.git")
        let localPath = (root as NSString).appendingPathComponent("local")
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-delete-lock-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(at: dbURL)
        }

        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Git.initialize()
        _ = try Repository.create(at: remotePath, bare: true)

        let uuid = UUID().uuidString.lowercased()
        let recovery = try keySetFile(name: "home-\(uuid)", type: KeySet.typeRecovery)
        let repository = try Repository.create(at: localPath, bare: false)
        try repository.createCommit(
            message: "seed recovery key",
            files: [
                (path: "gitdb/version", content: "\(DatabaseVersion.current)\n"),
                recovery,
            ]
        )
        try repository.addRemote(name: "origin", url: remotePath)
        try repository.push(remoteName: "origin", branchName: "main")

        let registry = ManifestRegistry()
        let database = try ManifestDatabase(databaseURL: dbURL, registry: registry)
        let gitDB = GitDatabase(repository: repository, database: database, registry: registry)
        let acquireSignal = MutationLockAcquireSignal()

        let holdingTask = Task {
            try await repository.withMutationLock {
                await acquireSignal.markAcquired()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await acquireSignal.waitUntilAcquired()

        let deleteTask = Task {
            try await RecoveryKeyManager().deleteRecoveryKey(
                uuid: uuid,
                repository: repository,
                gitDB: gitDB
            )
        }

        let contended = try await repository.tryWithMutationLock { true }
        #expect(contended == nil)

        try await holdingTask.value
        try await deleteTask.value

        #expect(!repository.fileExists(at: recovery.path))
    }

    private func keySetFile(
        name: String,
        type: String
    ) throws -> (path: String, content: String) {
        let keySet = KeySet(
            apiVersion: KeySet.apiVersionValue,
            kind: KeySet.kindValue,
            metadata: .init(name: name),
            spec: .init(
                type: type,
                mtlsPublicKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHRl+gi7RtSRc6vdZ+Yi9UDbHAjG6AU7bGguZE6PrPipUw+vUZxniQRRaMy/rwuKaIM/KRmDaslS/CpN5+1NvJE= phone",
                agePublicKey: "age1gffmd3cp4aae4ellqlqladxvtej9za6qsqpyquudjrwj06j4q95qqn5m8a"
            )
        )
        return (KeySet.path(name: name), try keySet.yaml())
    }
}
