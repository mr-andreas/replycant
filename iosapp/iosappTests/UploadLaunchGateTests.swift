import Testing
@testable import iosapp

// The photo-library scan enumerates every asset. These cases pin when a
// foreground launch may start it, so the scan does not run while the
// first thumbnails are still loading.
@Suite("Upload launch gate")
struct UploadLaunchGateTests {
    @Test("Metadata has to return before any scan, including a failed load")
    func testMetadataMustBeReady() {
        #expect(!UploadLaunchGate.shouldStart(
            metadataReady: false,
            timelineHasItems: false,
            loadFailed: true,
            viewportResolved: true,
            timedOut: true
        ))
    }

    @Test("An empty timeline has no thumbnails to protect")
    func testEmptyTimelineStartsAtMetadata() {
        #expect(UploadLaunchGate.shouldStart(
            metadataReady: true,
            timelineHasItems: false,
            loadFailed: false,
            viewportResolved: false,
            timedOut: false
        ))
    }

    @Test("A failed load never shows the grid, so there is nothing to wait for")
    func testFailedLoadStartsAtMetadata() {
        #expect(UploadLaunchGate.shouldStart(
            metadataReady: true,
            timelineHasItems: true,
            loadFailed: true,
            viewportResolved: false,
            timedOut: false
        ))
    }

    @Test("Photos stay ahead of the scan until the visible cells resolve")
    func testPopulatedTimelineWaitsForTheViewport() {
        #expect(!UploadLaunchGate.shouldStart(
            metadataReady: true,
            timelineHasItems: true,
            loadFailed: false,
            viewportResolved: false,
            timedOut: false
        ))
        #expect(UploadLaunchGate.shouldStart(
            metadataReady: true,
            timelineHasItems: true,
            loadFailed: false,
            viewportResolved: true,
            timedOut: false
        ))
    }

    @Test("A stuck thumbnail cannot postpone upload for the whole session")
    func testTimeoutStartsTheScan() {
        #expect(UploadLaunchGate.shouldStart(
            metadataReady: true,
            timelineHasItems: true,
            loadFailed: false,
            viewportResolved: false,
            timedOut: true
        ))
    }
}
