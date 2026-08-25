import Testing
@testable import iosapp

// Ensures the canvas catalog stays complete as wizard steps are added,
// so a new screen cannot ship without a gallery tile.
struct AppScreenGalleryTests {
    // Ensures every first-launch step has a named tile so onboarding
    // review does not miss a newly added screen. Recover access already
    // covers RecoveryView, so the nested onboarding recover tile is omitted.
    @Test func galleryCoversEveryOnboardingStep() {
        let ids = Set(AppScreenGallery.all.map(\.id))
        for step in OnboardingStep.allCases where step != .recover {
            #expect(ids.contains("Onboarding / \(step)"))
        }
        #expect(!ids.contains("Onboarding / recover"))
    }

    // Ensures every recovery-wizard outcome is on the board, including
    // the screens that no real input can reach without a preview step.
    @Test func galleryCoversEveryRecoveryStep() {
        let ids = Set(AppScreenGallery.all.map(\.id))
        for step in RecoveryView.RecoveryStep.allCases {
            #expect(ids.contains("Recover access / \(step)"))
        }
    }

    // Keeps the status list under Recovery keys and the create-wizard
    // steps under Create recovery key so a new step still gets a tile.
    @Test func galleryCoversEveryRecoveryKeyStep() {
        let ids = Set(AppScreenGallery.all.map(\.id))
        for step in RecoveryKeyView.RecoveryKeyStep.allCases {
            let prefix = step == .status ? "Recovery keys" : "Create recovery key"
            #expect(ids.contains("\(prefix) / \(step)"))
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

    // Prevents a tile from drifting into the wrong section by requiring
    // the id prefix to match the catalog grouping title.
    @Test func galleryIdsMatchTheirSectionTitle() {
        for screen in AppScreenGallery.all {
            #expect(screen.id.hasPrefix("\(screen.section.title) / "))
        }
    }

    // Keeps every catalog grouping on the board so a later move cannot
    // leave a section empty and silently drop its preview.
    @Test func everyGallerySectionHasAtLeastOneScreen() {
        for section in GallerySection.allCases {
            #expect(!AppScreenGallery.screens(in: section).isEmpty)
        }
    }

    // Pins Components to shared states no flow tile can render, so pairing
    // chrome cannot drift back into that section.
    @Test func componentsSectionHoldsOnlySharedStates() {
        let ids = AppScreenGallery.screens(in: .components).map(\.id)
        #expect(ids == [
            "Components / scanner scanning",
            "Components / scanner permission",
            "Components / scanner error",
            "Components / progress complete",
        ])
    }

    // Places root-shell, timeline, upload, and settings tiles in their
    // own sections so Main cannot collect unrelated tab content again.
    @Test func mainTabTilesLiveInDedicatedSections() {
        let byId = Dictionary(
            uniqueKeysWithValues: AppScreenGallery.all.map { ($0.id, $0.section) }
        )
        #expect(byId["App shell / tabs"] == .appShell)
        #expect(byId["App shell / resync"] == .appShell)
        #expect(byId["Timeline / empty"] == .timeline)
        #expect(byId["Timeline / loading"] == .timeline)
        #expect(byId["Timeline / error"] == .timeline)
        #expect(byId["Upload / idle"] == .upload)
        #expect(byId["Upload / syncing"] == .upload)
        #expect(byId["Upload / completed"] == .upload)
        #expect(byId["Upload / failed"] == .upload)
        #expect(byId["Settings / list"] == .settings)
        #expect(byId["Settings / recovery warning"] == .settings)
    }

    // Pins Settings to the list, warning badge, and every Advanced
    // destination so a new settings page cannot ship without a tile.
    @Test func settingsSectionCoversEverySubScreen() {
        let ids = AppScreenGallery.screens(in: .settings).map(\.id)
        #expect(ids == [
            "Settings / list",
            "Settings / recovery warning",
            "Settings / repository",
            "Settings / sync",
            "Settings / playback",
            "Settings / cache",
        ])
    }

    // More than four tiles switch to two rows so Canvas stays under the
    // 2200pt height that still paints, instead of a blank 3000pt board.
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
