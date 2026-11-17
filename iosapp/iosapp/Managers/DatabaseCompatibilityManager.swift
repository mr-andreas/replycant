import Combine
import GitDB

// Holds the current gitdb/version refusal so the banner and write
// paths share one source of truth. An older library stays visible
// while pulls wait for the server to upgrade it. Any other refusal
// stays up for the rest of the process.
@MainActor
final class DatabaseCompatibilityManager: ObservableObject {
    static let shared = DatabaseCompatibilityManager()

    @Published private(set) var incompatibility: DatabaseIncompatibility?
    @Published private(set) var pendingFormatResetMessage: String?

    private init() {}

    // Records a version refusal so the shell can keep showing it while
    // sync decides whether another pull could clear it.
    func report(_ error: DatabaseVersionError) {
        incompatibility = DatabaseIncompatibility(error)
    }

    // Clears the banner after a pull of a compatible repository,
    // including gitd finishing an upgrade the client was waiting on.
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

    // Surfaces a format-change pull that cannot rebase unpublished
    // local commits so the shell can offer reset-to-remote.
    func reportFormatTransitionDivergence(
        _ error: FormatTransitionPullError = .divergedDuringFormatChange
    ) {
        pendingFormatResetMessage = error.localizedDescription
    }

    // Clears the reset banner after HEAD has been moved to remote.
    func clearFormatReset() {
        pendingFormatResetMessage = nil
    }

    // Lets any catch site promote a format-transition refusal onto
    // the banner without each caller repeating the type check.
    func reportIfFormatTransitionError(_ error: Error) {
        guard let error = error as? FormatTransitionPullError else {
            return
        }
        reportFormatTransitionDivergence(error)
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
