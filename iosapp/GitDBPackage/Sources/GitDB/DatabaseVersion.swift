import Foundation
import LibGit2

// Names gitdb/version failures so clients can refuse an incompatible
// repository instead of guessing at an older layout.
public enum DatabaseVersionError: Error, Equatable, LocalizedError {
    case malformed
    case unsupported(found: Int, required: Int)
    case markerRemoved(previouslySynced: Int)

    // Tells the user what actually helps: update the app when the
    // library is newer, run the migration tool when it is older, and
    // restore a stripped marker instead of treating absence as fatal.
    public var userGuidance: String {
        switch self {
        case .unsupported(let found, let required) where found > required:
            return "This library uses database format \(found). This app supports format \(required). Update the app to continue."
        case .unsupported(let found, let required):
            return "This library uses database format \(found). This app supports format \(required). Run the migration tool to continue."
        case .markerRemoved(let previouslySynced):
            return "This library's database format marker was removed after this app last synced format \(previouslySynced). This is unsafe to open. Restore the marker to continue."
        case .malformed:
            return "This library uses an incompatible database format and cannot be opened. Create a new library to continue - resyncing will not help."
        }
    }

    // Surfaces the same guidance through LocalizedError so upload and
    // settings screens do not show the raw marker-parse string.
    public var errorDescription: String? {
        userGuidance
    }
}

// Names a pull that would rebase unpublished local commits onto a
// newer database format, which cannot be merged incrementally.
public enum FormatTransitionPullError: Error, Equatable, LocalizedError {
    case divergedDuringFormatChange

    public var errorDescription: String? {
        "This library was migrated to a new database format while this device had unpublished changes. Discard those local changes to continue."
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

    // Accepts the compiled pin and the pre-marker integer 0 so old
    // alpha libraries stay readable until a later migration writes 1.
    // The comparison is an explicit set, not `<= current`, so a future
    // bump to 2 does not silently keep accepting 1.
    public static func isAccepted(_ version: Int) -> Bool {
        version == 0 || version == current
    }

    // Refuses any integer that is not in the accepted set so a
    // tampered value can only deny service.
    public static func requireAccepted(_ version: Int) throws {
        guard isAccepted(version) else {
            throw DatabaseVersionError.unsupported(found: version, required: current)
        }
    }

    // Parses a present marker and refuses any value outside the
    // accepted set. Absence is handled by `read`, not by this parser.
    public static func requireSupported(_ raw: String) throws {
        try requireAccepted(try parse(raw))
    }

    // Reads the marker from one commit so pull can compare the remote
    // format against the local cache before deciding to rebase.
    // Absence is version 0, the in-code stand-in for old alpha repos.
    public static func read(in repository: Repository, commitOid: String) throws -> Int {
        guard let data = try repository.readBlobDataAtCommit(commitOid: commitOid, filepath: path) else {
            return 0
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DatabaseVersionError.malformed
        }
        return try parse(text)
    }

    // Reads the marker from one commit so sync can reject a fetched
    // format this client does not accept before any manifest work starts.
    public static func requireSupported(in repository: Repository, commitOid: String) throws {
        try requireAccepted(try read(in: repository, commitOid: commitOid))
    }

    // Refuses a later-absent marker when this cache was built from a
    // higher format so a hostile strip cannot look like an old library.
    public static func requireNoDowngrade(observed: Int, stored: Int) throws {
        if observed < stored {
            throw DatabaseVersionError.markerRemoved(previouslySynced: stored)
        }
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
