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

    // Keeps the in-app gallery host off unless an explicit launch
    // argument asks for it, so normal debug launches still show
    // ContentView.
    @Test func shouldShowGalleryRequiresExplicitLaunchArgument() {
        #expect(AppScreenGallery.shouldShowGallery(arguments: []) == false)
        #expect(
            AppScreenGallery.shouldShowGallery(arguments: ["--uitesting"]) == false
        )
        #expect(
            AppScreenGallery.shouldShowGallery(arguments: ["--gallery"]) == true
        )
    }

    // Canvas silently blanks boards at 3000pt tall while 2200pt
    // boards render. Two rows stay under that working height.
    @Test func canvasLayoutKeepsEverySectionUnderWorkingHeight() {
        for section in GallerySection.allCases {
            let layout = AppScreenGallery.canvasLayout(
                tileCount: AppScreenGallery.screens(in: section).count
            )
            #expect(layout.height <= AppScreenGallery.workingCanvasHeight)
            #expect(layout.rows <= 2)
        }
    }

    // Nine onboarding tiles need five columns to stay on two rows
    // instead of the three-row 3000pt board that Canvas left blank.
    @Test func canvasLayoutUsesTwoRowsOnceASectionExceedsFourTiles() {
        let onboarding = AppScreenGallery.canvasLayout(tileCount: 9)
        #expect(onboarding.columns == 5)
        #expect(onboarding.rows == 2)
        #expect(onboarding.width == 2170)
        #expect(onboarding.height == 1876)

        let linking = AppScreenGallery.canvasLayout(tileCount: 4)
        #expect(linking.columns == 4)
        #expect(linking.rows == 1)
        #expect(linking.width == 1744)
        #expect(linking.height == 958)
    }
}
