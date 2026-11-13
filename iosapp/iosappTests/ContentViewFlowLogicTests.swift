import Foundation
import Testing
@testable import iosapp
import LibGit2

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

    // A kill during pairing saves the server before the tailnet exists, so
    // launch must drop that leftover and show setup again. A kill later,
    // once the tailnet is saved, still has a path back through resync.
    @Test func isAbandonedPairingOnlyWhenServerSavedWithoutATailnet() {
        #expect(
            ContentView.isAbandonedPairing(
                isRepoInitialized: false,
                isServerConfigured: true,
                isTailnetConfigured: false
            )
        )
        #expect(
            ContentView.isAbandonedPairing(
                isRepoInitialized: false,
                isServerConfigured: true,
                isTailnetConfigured: true
            ) == false
        )
        #expect(
            ContentView.isAbandonedPairing(
                isRepoInitialized: true,
                isServerConfigured: true,
                isTailnetConfigured: false
            ) == false
        )
        #expect(
            ContentView.isAbandonedPairing(
                isRepoInitialized: false,
                isServerConfigured: false,
                isTailnetConfigured: false
            ) == false
        )
    }

    // An existing library has to be recognized before the first frame, so a
    // paired device opens on the timeline instead of a resync retry screen.
    @Test func repositoryExistsAtLaunchDetectsAnInitializedRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(ContentView.repositoryExistsAtLaunch(path: empty.path) == false)

        let repoPath = root.appendingPathComponent("repo", isDirectory: true).path
        _ = try Repository.create(at: repoPath)
        #expect(ContentView.repositoryExistsAtLaunch(path: repoPath) == true)
    }

    // The retry screen means a resync was attempted and the library is still
    // missing. Before the launch check finishes, that screen would hide the
    // timeline on every cold start.
    @Test func shouldShowResyncRetryOnlyAfterTheLaunchCheckFinishes() {
        #expect(
            ContentView.shouldShowResyncRetry(
                canAutoResync: true,
                hasFinishedLaunchCheck: false
            ) == false
        )
        #expect(
            ContentView.shouldShowResyncRetry(
                canAutoResync: true,
                hasFinishedLaunchCheck: true
            ) == true
        )
        #expect(
            ContentView.shouldShowResyncRetry(
                canAutoResync: false,
                hasFinishedLaunchCheck: true
            ) == false
        )
        #expect(
            ContentView.shouldShowResyncRetry(
                canAutoResync: false,
                hasFinishedLaunchCheck: false
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
