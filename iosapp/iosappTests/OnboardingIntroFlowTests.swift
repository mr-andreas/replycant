import Testing
@testable import iosapp

// Verifies onboarding intro metadata stays aligned with the product value narrative.
struct OnboardingIntroFlowTests {

    // Ensures the intro step has a user-facing navigation title used in previews and flow checks.
    @Test func introStepHasExpectedTitle() {
        #expect(OnboardingStep.intro.title == "Welcome")
    }

    // Ensures the onboarding intro keeps exactly three value-prop screens in the expected order.
    @Test func introPagesContainExpectedContent() {
        let pages = OnboardingIntroPage.defaultPages
        #expect(pages.count == 3)

        #expect(pages[0].iconName == nil)
        #expect(pages[0].logoName == "ReplycantLogo")
        #expect(pages[0].title == "Welcome to Replycant")

        #expect(pages[1].iconName == "lock.shield")
        #expect(pages[1].title == "Your data stays yours")

        #expect(pages[2].iconName == "arrow.triangle.branch")
        #expect(pages[2].title == "Durable and portable")
    }

    // Ensures users acknowledge key-loss risk before setup proceeds to
    // scanner-based bootstrap so encryption consequences are explicit.
    @Test func encryptionDisclaimerCopyAndTitleMatchExpectedText() {
        #expect(OnboardingView.encryptionDisclaimerText == "Replycant encrypts both media files and metadata. Encryption keys are stored only on your devices and are never stored on the server. If these keys are lost, your entire library will be permanently inaccessible. Uninstalling the iOS app removes this device's keys and can cause permanent data loss unless another device has already been granted access.")
        #expect(OnboardingView.encryptionDisclaimerAcknowledgeLabel == "I understand")
        #expect(OnboardingStep.encryptionDisclaimer.title == "Encryption Warning")
    }

    // Ensures create-library onboarding points users to server setup guidance
    // before the scanner step so required infrastructure is explicit.
    @Test func serverSetupGuideCopyAndTitleMatchExpectedText() {
        #expect(OnboardingView.serverSetupGuideText == "Before you continue, set up a Replycant server and make sure it's reachable from this device. Follow the guide below, then return here to scan your server QR code.")
        #expect(OnboardingView.serverSetupGuideURL.absoluteString == "https://github.com/mr-andreas/replycant#getting-started")
        #expect(OnboardingStep.serverSetupGuide.title == "Server Setup")
    }
}
