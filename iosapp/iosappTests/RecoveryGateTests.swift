import Testing
@testable import iosapp

// Verifies recovery can only run on fresh installs to avoid key/identity overlap on configured devices.
struct RecoveryGateTests {
    // Rejects when either server trust or repository state indicates onboarding already completed.
    @Test func rejectsWhenServerConfiguredOrRepositoryExists() {
        #expect(RecoveryKeyManager.shouldRejectRecovery(isServerConfigured: true, repositoryExists: false))
        #expect(RecoveryKeyManager.shouldRejectRecovery(isServerConfigured: false, repositoryExists: true))
        #expect(RecoveryKeyManager.shouldRejectRecovery(isServerConfigured: true, repositoryExists: true))
    }

    // Allows recovery only when no local configuration and no repository are present.
    @Test func allowsOnlyFreshInstallState() {
        #expect(!RecoveryKeyManager.shouldRejectRecovery(isServerConfigured: false, repositoryExists: false))
    }
}
