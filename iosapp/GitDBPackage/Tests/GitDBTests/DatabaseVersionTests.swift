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

    @Test func requireSupportedPinsExactMatch() throws {
        try DatabaseVersion.requireSupported("1\n")
        #expect(throws: DatabaseVersionError.unsupported(found: 2, required: 1)) {
            try DatabaseVersion.requireSupported("2\n")
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
            files: [("gitdb/version", "1\n")]
        )
        let head = try #require(repository.headOID())
        try DatabaseVersion.requireSupported(in: repository, commitOid: head)
    }

    @Test func userGuidanceAsksToUpdateWhenMarkerIsNewer() {
        #expect(
            DatabaseVersionError.unsupported(found: 2, required: 1).userGuidance
                == "This library uses database format 2. This app supports format 1. Update the app to continue."
        )
    }

    @Test func userGuidanceAsksForNewLibraryWhenMarkerIsMissingOrOlder() {
        let expected = "This library uses an incompatible database format and cannot be opened. Create a new library to continue - resyncing will not help."
        #expect(DatabaseVersionError.missing.userGuidance == expected)
        #expect(DatabaseVersionError.malformed.userGuidance == expected)
        #expect(DatabaseVersionError.unsupported(found: 1, required: 2).userGuidance == expected)
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

    @Test func requireSupportedRejectsMissingMarker() throws {
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
        #expect(throws: DatabaseVersionError.missing) {
            try DatabaseVersion.requireSupported(in: repository, commitOid: head)
        }
    }
}
