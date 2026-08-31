import Combine
import GitDB

// Holds a permanent gitdb/version refusal so the banner and write
// paths share one source of truth instead of each retry looking like
// a transient sync blip.
@MainActor
final class DatabaseCompatibilityManager: ObservableObject {
    static let shared = DatabaseCompatibilityManager()

    @Published private(set) var incompatibility: DatabaseIncompatibility?

    private init() {}

    // Records a version refusal so the shell can keep showing it after
    // periodic sync has stopped retrying.
    func report(_ error: DatabaseVersionError) {
        incompatibility = DatabaseIncompatibility(error)
    }

    // Clears the banner after a successful sync against a compatible
    // repository, which only happens if the user starts a new library.
    func clear() {
        incompatibility = nil
    }

    // Lets any catch site promote a version refusal onto the banner
    // without each caller repeating the type check.
    func reportIfVersionError(_ error: Error) {
        guard let error = error as? DatabaseVersionError else {
            return
        }
        report(error)
    }
}

// Maps a DatabaseVersionError to the user-facing copy the banner shows
// so upload and settings do not invent a different remedy.
struct DatabaseIncompatibility: Equatable {
    let userMessage: String
    let isNewerThanClient: Bool

    init(_ error: DatabaseVersionError) {
        userMessage = error.userGuidance
        if case .unsupported(let found, let required) = error, found > required {
            isNewerThanClient = true
        } else {
            isNewerThanClient = false
        }
    }
}
