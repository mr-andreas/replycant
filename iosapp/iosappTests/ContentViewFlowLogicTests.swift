import Testing
@testable import iosapp

// Verifies ContentView flow decisions use shared auto-resync behavior for fresh installs.
struct ContentViewFlowLogicTests {

    // Ensures Canvas is detected only from the Xcode preview environment flag.
    @Test func isRunningForPreviewsRequiresXcodePreviewFlag() {
        #expect(ContentView.isRunningForPreviews(environment: [:]) == false)
        #expect(ContentView.isRunningForPreviews(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "0"]) == false)
        #expect(ContentView.isRunningForPreviews(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]) == true)
    }

    // Ensures onboarding is skipped only when an explicit environment override is present.
    @Test func shouldSkipOnboardingRequiresExplicitEnvironmentFlag() {
        #expect(ContentView.shouldSkipOnboarding(environment: [:]) == false)
        #expect(ContentView.shouldSkipOnboarding(environment: ["SKIP_ONBOARDING": "0"]) == false)
        #expect(ContentView.shouldSkipOnboarding(environment: ["SKIP_ONBOARDING": "1"]) == true)
    }

    // Ensures missing repositories with valid credentials trigger the same auto-resync path used post-wipe.
    @Test func shouldAutoResyncWhenRepositoryMissingAndCredentialsExist() {
        #expect(
            ContentView.shouldAutoResync(
                isRepoInitialized: false,
                shouldSkipOnboarding: false,
                isConfigured: true,
                hasIdentity: true
            ) == true
        )
    }

    // Prevents auto-resync in states where onboarding or existing repository state should take precedence.
    @Test func shouldAutoResyncReturnsFalseForNonResyncStates() {
        #expect(
            ContentView.shouldAutoResync(
                isRepoInitialized: true,
                shouldSkipOnboarding: false,
                isConfigured: true,
                hasIdentity: true
            ) == false
        )
        #expect(
            ContentView.shouldAutoResync(
                isRepoInitialized: false,
                shouldSkipOnboarding: true,
                isConfigured: true,
                hasIdentity: true
            ) == false
        )
        #expect(
            ContentView.shouldAutoResync(
                isRepoInitialized: false,
                shouldSkipOnboarding: false,
                isConfigured: false,
                hasIdentity: true
            ) == false
        )
        #expect(
            ContentView.shouldAutoResync(
                isRepoInitialized: false,
                shouldSkipOnboarding: false,
                isConfigured: true,
                hasIdentity: false
            ) == false
        )
    }

    // A schema wipe leaves the git library in place and the SQL cache empty,
    // which is the only launch state that should rebuild the index.
    @Test func shouldRebuildIndexOnLaunchOnlyWhenRepositoryExistsAndCacheIsUnhydrated() {
        #expect(ContentView.shouldRebuildIndexOnLaunch(isRepoInitialized: true, isHydrated: false))
        #expect(ContentView.shouldRebuildIndexOnLaunch(isRepoInitialized: true, isHydrated: true) == false)
        #expect(ContentView.shouldRebuildIndexOnLaunch(isRepoInitialized: false, isHydrated: false) == false)
        #expect(ContentView.shouldRebuildIndexOnLaunch(isRepoInitialized: false, isHydrated: true) == false)
    }

    // Keeps the Settings badge visible only while no recovery key exists so
    // users are nudged before a lockout, then cleared after a key is created.
    @Test func shouldShowRecoveryWarningWhenNoRecoveryKeyExists() {
        #expect(ContentView.shouldShowRecoveryWarning(hasRecoveryKey: false) == true)
        #expect(ContentView.shouldShowRecoveryWarning(hasRecoveryKey: true) == false)
    }
}
