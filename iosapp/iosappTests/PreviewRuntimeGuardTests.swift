import Testing
@testable import iosapp

// Ensures Canvas-only runtime guards stay inert in the app and skip
// capture/libgit2 work that cannot succeed in the Previews agent.
struct PreviewRuntimeGuardTests {
    // Ensures the scanner uses a live session except when Xcode is hosting
    // the view in Canvas, where no capture device or TCC prompt exists.
    @Test func shouldUseLiveCameraIsFalseOnlyInPreviews() {
        #expect(QRCodeScannerView.shouldUseLiveCamera(environment: [:]) == true)
        #expect(
            QRCodeScannerView.shouldUseLiveCamera(
                environment: ["XCODE_RUNNING_FOR_PREVIEWS": "0"]
            ) == true
        )
        #expect(
            QRCodeScannerView.shouldUseLiveCamera(
                environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]
            ) == false
        )
    }

    // Ensures a real timeline load runs only for production views that
    // were not parked in a preview state, so Canvas never reaches
    // uninitialized libgit2.
    @Test func shouldLoadTimelineOnlyOutsidePreviewsWithoutPreviewState() {
        #expect(
            TimelineView.shouldLoadTimeline(
                previewState: nil,
                isRunningForPreviews: false
            ) == true
        )
        #expect(
            TimelineView.shouldLoadTimeline(
                previewState: nil,
                isRunningForPreviews: true
            ) == false
        )
        #expect(
            TimelineView.shouldLoadTimeline(
                previewState: .empty,
                isRunningForPreviews: false
            ) == false
        )
        #expect(
            TimelineView.shouldLoadTimeline(
                previewState: .loading,
                isRunningForPreviews: true
            ) == false
        )
        #expect(
            TimelineView.shouldLoadTimeline(
                previewState: .error("LFS URL not configured"),
                isRunningForPreviews: false
            ) == false
        )
    }

    // Ensures repository settings skip git status work in Canvas and
    // gallery tiles, where Git.initialize() never ran.
    @Test func shouldLoadRepositoryStatusOnlyOutsidePreviewsWithoutPreviewState() {
        #expect(
            RepositorySettingsView.shouldLoadRepositoryStatus(
                previewState: nil,
                isRunningForPreviews: false
            ) == true
        )
        #expect(
            RepositorySettingsView.shouldLoadRepositoryStatus(
                previewState: nil,
                isRunningForPreviews: true
            ) == false
        )
        #expect(
            RepositorySettingsView.shouldLoadRepositoryStatus(
                previewState: .sample,
                isRunningForPreviews: false
            ) == false
        )
        #expect(
            RepositorySettingsView.shouldLoadRepositoryStatus(
                previewState: .sample,
                isRunningForPreviews: true
            ) == false
        )
    }

    // Ensures cache settings skip disk-stat I/O in Canvas and seed
    // representative numbers from a parked snapshot instead.
    @Test func shouldLoadDiskStatsOnlyOutsidePreviewsWithoutPreviewStats() {
        #expect(
            CacheSettingsView.shouldLoadDiskStats(
                previewStats: nil,
                isRunningForPreviews: false
            ) == true
        )
        #expect(
            CacheSettingsView.shouldLoadDiskStats(
                previewStats: nil,
                isRunningForPreviews: true
            ) == false
        )
        #expect(
            CacheSettingsView.shouldLoadDiskStats(
                previewStats: .sample,
                isRunningForPreviews: false
            ) == false
        )
        #expect(
            CacheSettingsView.shouldLoadDiskStats(
                previewStats: .sample,
                isRunningForPreviews: true
            ) == false
        )
    }
}
