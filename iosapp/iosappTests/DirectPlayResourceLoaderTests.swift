import Foundation
import Testing
@testable import iosapp

// Covers DirectPlayResourceLoader teardown so discarded players cannot be
// revived by in-flight seek-range callbacks after fullscreen dismiss.
struct DirectPlayResourceLoaderTests {
    // Ensures invalidate drops seek-resume callbacks, which is what stops a
    // late range-replacement from calling play() after the UI is gone.
    @Test func invalidateClearsSeekRangeCallbacks() throws {
        let url = try #require(URL(string: "https://example.com/decryptd/objects/abc"))
        let loader = DirectPlayResourceLoader(
            httpURL: url,
            headers: [:],
            mimeType: "video/mp4",
            clientIdentity: nil,
            pinnedCA: nil
        )
        loader.onSeekRangeReplacementStarted = {}
        loader.onSeekRangeReplacementReady = {}
        #expect(loader.onSeekRangeReplacementStarted != nil)
        #expect(loader.onSeekRangeReplacementReady != nil)

        loader.invalidate()

        #expect(loader.onSeekRangeReplacementStarted == nil)
        #expect(loader.onSeekRangeReplacementReady == nil)
    }
}
