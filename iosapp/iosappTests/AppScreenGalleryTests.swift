import Testing
@testable import iosapp

// Ensures the canvas catalog stays complete as wizard steps are added,
// so a new screen cannot ship without a gallery tile.
struct AppScreenGalleryTests {
    // Ensures every first-launch step has a named tile so onboarding
    // review does not miss a newly added screen.
    @Test func galleryCoversEveryOnboardingStep() {
        let ids = Set(AppScreenGallery.all.map(\.id))
        for step in OnboardingStep.allCases {
            #expect(ids.contains("Onboarding / \(step)"))
        }
    }

    // Ensures every recovery-wizard outcome is on the board, including
    // the screens that no real input can reach without a preview step.
    @Test func galleryCoversEveryRecoveryStep() {
        let ids = Set(AppScreenGallery.all.map(\.id))
        for step in RecoveryView.RecoveryStep.allCases {
            #expect(ids.contains("Recovery / \(step)"))
        }
    }

    // Ensures every create-wizard step has a tile so recovery-key
    // review stays complete when a new step is added.
    @Test func galleryCoversEveryRecoveryKeyStep() {
        let ids = Set(AppScreenGallery.all.map(\.id))
        for step in RecoveryKeyView.RecoveryKeyStep.allCases {
            #expect(ids.contains("Recovery Key / \(step)"))
        }
    }

    // Ensures catalog ids stay unique so coverage checks cannot hide a
    // missing screen behind a duplicate name.
    @Test func galleryScreenIdsAreUnique() {
        let ids = AppScreenGallery.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
