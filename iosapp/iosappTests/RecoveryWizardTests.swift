import Testing
import UIKit
@testable import iosapp

// Verifies recovery wizard routing stays deterministic and easy to follow as screens evolve.
struct RecoveryWizardTests {
    // Ensures create wizard labels stay stable for accessibility and navigation consistency.
    @Test func recoveryKeyWizardStepTitles() {
        #expect(RecoveryKeyView.RecoveryKeyStep.status.title == "Recovery Key")
        #expect(RecoveryKeyView.RecoveryKeyStep.processing.title == "Creating Key")
        #expect(RecoveryKeyView.RecoveryKeyStep.created.title == "Recovery Key Created")
        #expect(RecoveryKeyView.RecoveryKeyStep.error.title == "Error")
    }

    // Ensures the status screen explains why creating a recovery key matters.
    @Test func recoveryKeyStatusDescriptionCopy() {
        #expect(
            RecoveryKeyView.statusDescription
                == "Protect yourself from being locked out. A recovery key restores access when you can’t use an existing device to connect to your Replycant server."
        )
    }

    // Ensures revoke guidance copy remains explicit after successful recovery.
    @Test func recoveryWizardRevokeCopy() {
        #expect(RecoveryView.revokeCtaLabel == "Revoke used key")
        #expect(RecoveryView.continueCtaLabel == "Continue")
        #expect(RecoveryView.revokeDoneMessage == "Used key revoked. Create a new recovery key in Settings.")
        #expect(RecoveryView.cancelCtaLabel == "Cancel")
    }

    // Ensures step 1 starts with the current device name so users can accept it without typing.
    @Test func recoveryKeyDefaultLabelUsesDeviceName() {
        #expect(RecoveryKeyView.defaultLabel() == UIDevice.current.name)
        #expect(RecoveryKeyView.canAdvanceFromName(label: RecoveryKeyView.defaultLabel()))
    }

    // Ensures the nav chevron walks one wizard step instead of always leaving to Settings.
    @Test func recoveryKeyWizardBackDestinations() {
        #expect(RecoveryKeyView.backDestination(from: .status) == nil)
        #expect(RecoveryKeyView.backDestination(from: .name) == .status)
        #expect(RecoveryKeyView.backDestination(from: .password) == .name)
        #expect(RecoveryKeyView.backDestination(from: .error) == .status)
        #expect(RecoveryKeyView.backDestination(from: .processing) == nil)
        #expect(RecoveryKeyView.backDestination(from: .created) == nil)
    }

    // Ensures Done stays locked until the share sheet has been opened.
    @Test func recoveryKeyCreatedStepDismissal() {
        #expect(!RecoveryKeyView.canDismissCreatedKey(hasShared: false))
        #expect(RecoveryKeyView.canDismissCreatedKey(hasShared: true))
    }

    // Ensures the created-step copy tells users to save the backup off-device.
    @Test func recoveryKeyCreatedStepCopy() {
        #expect(RecoveryKeyView.createdStepHeading == "Recovery key created")
        #expect(RecoveryKeyView.createdStepBody.contains("outside this device"))
        #expect(RecoveryKeyView.createdStepBody.contains("password is not included"))
        #expect(RecoveryKeyView.createdStepShareLabel == "Share recovery key")
        #expect(RecoveryKeyView.createdStepDoneLabel == "Done")
    }

    // Ensures create-wizard headings and subtitles stay consistent with
    // other pairing steps and warn that the backup password cannot be reset.
    @Test func recoveryKeyWizardStepCopy() {
        #expect(RecoveryKeyView.nameStepHeading == "Name this recovery key")
        #expect(!RecoveryKeyView.nameStepSubtitle.isEmpty)
        #expect(RecoveryKeyView.passwordStepHeading == "Set a backup password")
        #expect(RecoveryKeyView.passwordStepSubtitle.contains("cannot be reset"))
    }

    // Ensures mismatch copy appears only after both fields are filled
    // and disagree, so empty or in-progress entry is not treated as an error.
    @Test func recoveryKeyPasswordWarning() {
        #expect(RecoveryKeyView.passwordWarning(password: "", confirmPassword: "") == nil)
        #expect(RecoveryKeyView.passwordWarning(password: "secret", confirmPassword: "") == nil)
        #expect(RecoveryKeyView.passwordWarning(password: "", confirmPassword: "secret") == nil)
        #expect(RecoveryKeyView.passwordWarning(password: "secret", confirmPassword: "secret") == nil)
        #expect(
            RecoveryKeyView.passwordWarning(password: "secret", confirmPassword: "other")
                == RecoveryKeyView.passwordMismatchMessage
        )
    }

    // Ensures create wizard only advances when label is non-empty and password fields match.
    @Test func recoveryKeyWizardAdvancePredicates() {
        #expect(!RecoveryKeyView.canAdvanceFromName(label: ""))
        #expect(RecoveryKeyView.canAdvanceFromName(label: "home-safe"))
        #expect(!RecoveryKeyView.canAdvanceFromPassword(password: "a", confirmPassword: "b"))
        #expect(RecoveryKeyView.canAdvanceFromPassword(password: "same", confirmPassword: "same"))
    }

    // Ensures deep-link input bypasses the bundle collection steps and goes straight to password.
    @Test func recoveryWizardInitialStepFromDeepLink() {
        #expect(RecoveryView.initialStep(for: nil) == .start)
        #expect(RecoveryView.initialStep(for: "") == .start)
        #expect(RecoveryView.initialStep(for: "replycant://recover?v=1&d=abc") == .password)
    }

    // Ensures bundle validation routes to password when valid and to error when malformed.
    @Test func recoveryWizardBundleValidationRouting() throws {
        let plaintext = RecoveryBundle.Plaintext(
            version: 1,
            label: "test",
            uuid: "00000000-0000-0000-0000-000000000000",
            created: "2026-08-10T00:00:00Z",
            discoveryURL: "http://replycant.local:8080",
            caSHA256: String(repeating: "a", count: 64),
            p256PrivateKeyPEM: """
            -----BEGIN EC PRIVATE KEY-----
            MHcCAQEEID4fXxFf2A62NV6yIh5fBO7F9RheR8fIuYzDX7r1iWzqoAoGCCqGSM49
            AwEHoUQDQgAE4QxF9i7bE7Emo5zwHWQ/PF2hVGRjQ0gFzQkk+zROf4xIhT4uHnq+
            qz6mJfXwAhgB+Fkg4anSg93vB7DbeGkBMQ==
            -----END EC PRIVATE KEY-----
            """,
            agePrivateKey: "AGE-SECRET-KEY-1QG8G4Y8R8PFQ7FSPAVM6Y8W2FM9R8R0VHW8Q7M67QZTL0YEAX5G5Q4JQ2T"
        )
        let envelope = try RecoveryBundle.encrypt(plaintext: plaintext, password: "password123")
        let validJSON = try RecoveryBundle.envelopeJSONString(envelope)

        #expect(RecoveryView.nextStepAfterBundleValidation(input: validJSON) == .password)
        #expect(RecoveryView.nextStepAfterBundleValidation(input: "not-valid-json") == .error)
        #expect(RecoveryView.bundleBackDestination() == .start)
    }
}
