import LibGit2
import Testing
@testable import iosapp

// Verifies a 401 during recovery is treated as a deleted key, not a generic
// network failure, once the recovery bundle has already pinned this server.
struct RecoveryRevokedKeyTests {
    // Ensures the transport helper recognizes a 401 both as a typed transport
    // error and after libgit2 has flattened it into a GitError message.
    @Test func indicatesHTTPStatusMatches401FromTransportAndGitError() {
        #expect(
            MTLSTransportError.indicatesHTTPStatus(
                401,
                in: MTLSTransportError.networkError("HTTP error 401")
            )
        )
        #expect(
            MTLSTransportError.indicatesHTTPStatus(
                401,
                in: GitError.unknown("Network error: HTTP error 401")
            )
        )
        #expect(
            !MTLSTransportError.indicatesHTTPStatus(
                401,
                in: MTLSTransportError.networkError("HTTP error 403")
            )
        )
        #expect(
            !MTLSTransportError.indicatesHTTPStatus(
                401,
                in: GitError.unknown("Failed to initialize libgit2")
            )
        )
    }

    // Ensures only an HTTP 401 from the recovery identity becomes the named
    // "key not registered" error so other failures keep their original text.
    @Test func mapRecoveryAuthErrorRewrites401AndPassesOthersThrough() {
        let mapped401 = RecoveryKeyManager.mapRecoveryAuthError(
            MTLSTransportError.networkError("HTTP error 401")
        )
        #expect(mapped401 is RecoveryKeyManager.Error)
        if case RecoveryKeyManager.Error.recoveryKeyNotAuthorized = mapped401 {
            // Expected mapping.
        } else {
            Issue.record("expected recoveryKeyNotAuthorized, got \(mapped401)")
        }

        let wrapped401 = RecoveryKeyManager.mapRecoveryAuthError(
            GitError.unknown("Network error: HTTP error 401")
        )
        if case RecoveryKeyManager.Error.recoveryKeyNotAuthorized = wrapped401 {
            // Expected mapping through the flattened libgit2 message.
        } else {
            Issue.record("expected recoveryKeyNotAuthorized for GitError, got \(wrapped401)")
        }

        let original = GitError.unknown("disk I/O error")
        let mappedOther = RecoveryKeyManager.mapRecoveryAuthError(original)
        #expect(mappedOther.localizedDescription == original.localizedDescription)

        let forbidden = RecoveryKeyManager.mapRecoveryAuthError(
            MTLSTransportError.networkError("HTTP error 403")
        )
        #expect(!(forbidden is RecoveryKeyManager.Error))
    }

    // Keeps the rejected-key screen title and explanation stable so users
    // see why retrying the same deleted key cannot succeed.
    @Test func recoveryWizardKeyRejectedCopy() {
        #expect(RecoveryView.RecoveryStep.keyRejected.title == "Recovery Key Rejected")
        #expect(
            RecoveryView.keyRejectedMessage
                == "The server rejected this recovery key. It matches this server's certificate, so it was registered here before and has since been deleted. Use a different recovery key, or pair from a device that still has access."
        )
    }
}
