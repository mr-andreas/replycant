import Foundation
import GitDB
import LibGit2
import Testing
@testable import iosapp

// Verifies recovery key filename conventions so auth and encryption recipient scans keep working.
struct RecoveryKeyNamingTests {
    // Confirms listRecoveryKeys only returns entries that include both marked pub and age files.
    @Test func listRecoveryKeysRequiresPubAndAgePair() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("recovery-naming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let repo = try Repository.create(at: root, bare: false)
        let validUUID = UUID().uuidString.lowercased()
        let missingAgeUUID = UUID().uuidString.lowercased()
        let validLabel = "home-safe-primary"
        try repo.createCommit(
            message: "seed recovery pubkeys",
            files: [
                (path: "pubkeys/\(validLabel)-\(validUUID).recovery.pub", content: "ssh"),
                (path: "pubkeys/\(validLabel)-\(validUUID).recovery.age", content: "age"),
                (path: "pubkeys/missing-age-\(missingAgeUUID).recovery.pub", content: "ssh"),
                (path: "pubkeys/device-main.pub", content: "ssh"),
            ]
        )

        let records = try RecoveryKeyManager().listRecoveryKeys(repository: repo)
        #expect(records.count == 1)
        #expect(records[0].label == validLabel)
        #expect(records[0].uuid == validUUID)
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
        let pubPath = "pubkeys/home-\(uuid).recovery.pub"
        let agePath = "pubkeys/home-\(uuid).recovery.age"
        let repository = try Repository.create(at: localPath, bare: false)
        try repository.createCommit(
            message: "seed recovery key",
            files: [
                (path: "gitdb/version", content: "1\n"),
                (path: pubPath, content: "ssh"),
                (path: agePath, content: "age"),
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

        #expect(!repository.fileExists(at: pubPath))
        #expect(!repository.fileExists(at: agePath))
    }
}
