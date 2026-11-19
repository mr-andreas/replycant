import Foundation
import Testing
import LibGit2
@testable import GitDB

// Verifies gitdb/version parsing so iOS rejects the same markers as
// Go and TypeScript instead of accepting signed or padded integers.
struct DatabaseVersionTests {
    @Test func parseAcceptsExactInteger() throws {
        #expect(try DatabaseVersion.parse("1") == 1)
        #expect(try DatabaseVersion.parse("1\n") == 1)
        #expect(try DatabaseVersion.parse("42") == 42)
        #expect(try DatabaseVersion.parse("42\n") == 42)
    }

    @Test(arguments: [
        "",
        "\n",
        "0",
        "01",
        "+1",
        "-1",
        "1 2",
        "1\n2",
        "1 ",
        " 1",
        "abc",
        "1\r\n",
        "\u{FEFF}1",
        "1\n\n",
    ])
    func parseRejectsMalformedContent(_ input: String) {
        #expect(throws: DatabaseVersionError.malformed) {
            _ = try DatabaseVersion.parse(input)
        }
    }

    @Test func requireSupportedAcceptsPinnedVersionAndRejectsOthers() throws {
        let pin = DatabaseVersion.current
        try DatabaseVersion.requireSupported("\(pin)\n")
        try DatabaseVersion.requireAccepted(pin)
        #expect(throws: DatabaseVersionError.unsupported(found: pin - 1, required: pin)) {
            try DatabaseVersion.requireSupported("\(pin - 1)\n")
        }
        #expect(throws: DatabaseVersionError.unsupported(found: 0, required: pin)) {
            try DatabaseVersion.requireAccepted(0)
        }
        #expect(throws: DatabaseVersionError.unsupported(found: pin + 1, required: pin)) {
            try DatabaseVersion.requireAccepted(pin + 1)
        }
    }

    @Test func requireSupportedReadsCommitMarker() throws {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-version-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: repoPath) }
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        try repository.createCommit(
            message: "seed",
            files: [("gitdb/version", "\(DatabaseVersion.current)\n")]
        )
        let head = try #require(repository.headOID())
        try DatabaseVersion.requireSupported(in: repository, commitOid: head)
    }

    @Test func userGuidanceAsksToUpdateWhenMarkerIsNewer() {
        #expect(
            DatabaseVersionError.unsupported(found: DatabaseVersion.current + 1, required: DatabaseVersion.current).userGuidance
                == "This library uses database format \(DatabaseVersion.current + 1). This app supports format \(DatabaseVersion.current). Update the app to continue."
        )
    }

    @Test func userGuidanceAsksToMigrateWhenMarkerIsOlder() {
        #expect(
            DatabaseVersionError.unsupported(found: 1, required: DatabaseVersion.current).userGuidance
                == "This library uses database format 1. This app supports format \(DatabaseVersion.current). Restart the library server so it can upgrade the database, then try again."
        )
    }

    @Test func userGuidanceAsksForNewLibraryWhenMarkerIsMalformed() {
        #expect(
            DatabaseVersionError.malformed.userGuidance
                == "This library uses an incompatible database format and cannot be opened. Create a new library to continue - resyncing will not help."
        )
    }

    @Test func requireNoDowngradeRefusesLowerObserved() throws {
        try DatabaseVersion.requireNoDowngrade(observed: 0, stored: 0)
        try DatabaseVersion.requireNoDowngrade(observed: 1, stored: 0)
        #expect(throws: DatabaseVersionError.markerRemoved(previouslySynced: 1)) {
            try DatabaseVersion.requireNoDowngrade(observed: 0, stored: 1)
        }
    }

    // A later pull can only help when gitd has not yet migrated an
    // older library. A newer marker, a damaged marker, or a removed
    // marker stays refused no matter how many times the client fetches.
    @Test func olderFormatIsFixedByServerUpgrade() {
        #expect(
            DatabaseVersionError.unsupported(found: 1, required: DatabaseVersion.current)
                .isFixedByServerUpgrade
        )
        #expect(
            DatabaseVersionError.unsupported(found: DatabaseVersion.current + 1, required: DatabaseVersion.current)
                .isFixedByServerUpgrade == false
        )
        #expect(DatabaseVersionError.malformed.isFixedByServerUpgrade == false)
        #expect(
            DatabaseVersionError.markerRemoved(previouslySynced: 1)
                .isFixedByServerUpgrade == false
        )
    }

    @Test func userGuidanceWarnsWhenMarkerWasRemoved() {
        #expect(
            DatabaseVersionError.markerRemoved(previouslySynced: 1).userGuidance
                == "This library's database format marker was removed after this app last synced format 1. This is unsafe to open. Restore the marker to continue."
        )
    }

    @Test func requireSupportedIfHeadExistsSkipsUnbornRepository() throws {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-version-unborn-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: repoPath) }
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        try DatabaseVersion.requireSupportedIfHeadExists(in: repository)
    }

    @Test func readRejectsAbsentMarker() throws {
        let repoPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitdb-version-missing-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: repoPath) }
        try Git.initialize()
        let repository = try Repository.create(at: repoPath, bare: false)
        try repository.createCommit(
            message: "seed",
            files: [("notes/readme.txt", "hello")]
        )
        let head = try #require(repository.headOID())
        #expect(throws: DatabaseVersionError.malformed) {
            _ = try DatabaseVersion.read(in: repository, commitOid: head)
        }
        #expect(throws: DatabaseVersionError.malformed) {
            try DatabaseVersion.requireSupported(in: repository, commitOid: head)
        }
    }
}
