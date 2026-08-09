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
        try repo.createCommit(
            message: "seed recovery pubkeys",
            files: [
                (path: "pubkeys/home-safe-1111.recovery.pub", content: "ssh"),
                (path: "pubkeys/home-safe-1111.recovery.age", content: "age"),
                (path: "pubkeys/missing-age-2222.recovery.pub", content: "ssh"),
                (path: "pubkeys/device-main.pub", content: "ssh"),
            ]
        )

        let records = try RecoveryKeyManager().listRecoveryKeys(repository: repo)
        #expect(records.count == 1)
        #expect(records[0].label == "home-safe")
        #expect(records[0].uuid == "1111")
    }
}
