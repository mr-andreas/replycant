import Foundation
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
}
