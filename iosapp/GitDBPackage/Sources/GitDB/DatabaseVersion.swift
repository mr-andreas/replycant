import Foundation
import LibGit2

// Names gitdb/version failures so clients can refuse an incompatible
// repository instead of guessing at an older layout.
public enum DatabaseVersionError: Error, Equatable, LocalizedError {
    case missing
    case malformed
    case unsupported(found: Int, required: Int)

    // Tells the user what actually helps: update the app when the
    // library is newer, otherwise create a new library. Resyncing the
    // same remote cannot invent a compatible format.
    public var userGuidance: String {
        switch self {
        case .unsupported(let found, let required) where found > required:
            return "This library uses database format \(found). This app supports format \(required). Update the app to continue."
        case .missing, .malformed, .unsupported:
            return "This library uses an incompatible database format and cannot be opened. Create a new library to continue - resyncing will not help."
        }
    }

    // Surfaces the same guidance through LocalizedError so upload and
    // settings screens do not show the raw marker-parse string.
    public var errorDescription: String? {
        userGuidance
    }
}

// Pins the only database format this client will open so a plaintext
// marker cannot steer decryption onto a weaker path.
public enum DatabaseVersion {
    public static let current = 1
    public static let path = "gitdb/version"

    // Parses gitdb/version so three language clients reject the same
    // malformed markers instead of drifting into lenient acceptance.
    public static func parse(_ raw: String) throws -> Int {
        var text = raw
        if text.last == "\n" {
            text.removeLast()
        }
        guard !text.isEmpty else {
            throw DatabaseVersionError.malformed
        }
        guard text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            throw DatabaseVersionError.malformed
        }
        guard text.first != "0" else {
            throw DatabaseVersionError.malformed
        }
        guard let version = Int(text), version >= 1 else {
            throw DatabaseVersionError.malformed
        }
        return version
    }

    // Refuses any marker that is not an exact match for `current` so a
    // tampered value can only deny service.
    public static func requireSupported(_ raw: String) throws {
        let version = try parse(raw)
        guard version == current else {
            throw DatabaseVersionError.unsupported(found: version, required: current)
        }
    }

    // Reads the marker from one commit so sync can reject a fetched
    // format change before any manifest work starts.
    public static func requireSupported(in repository: Repository, commitOid: String) throws {
        guard let data = try repository.readBlobDataAtCommit(commitOid: commitOid, filepath: path) else {
            throw DatabaseVersionError.missing
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DatabaseVersionError.malformed
        }
        try requireSupported(text)
    }

    // Skips the check only for an unborn HEAD so first-epoch bootstrap
    // can write gitdb/version in the initial commit.
    public static func requireSupportedIfHeadExists(in repository: Repository) throws {
        guard let head = repository.headOID() else {
            return
        }
        try requireSupported(in: repository, commitOid: head)
    }
}
