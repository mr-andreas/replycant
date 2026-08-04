import Foundation
import Testing
@testable import iosapp

// Verifies playback-mode settings persistence so fullscreen playback picks the
// expected strategy before adaptive selection is implemented.
@Suite(.serialized)
struct PlaybackSettingsManagerTests {
    // Clears playback-mode defaults so tests can assert behavior from a known
    // baseline without leakage from previous runs.
    private func clearPlaybackSettings() {
        UserDefaults.standard.removeObject(forKey: "videoPlaybackMethod")
    }

    // Builds a minimal video timeline item fixture so selection tests can
    // exercise the public playback selection API.
    private func makeVideoItem() -> TimelineItem {
        let manifest = OriginalManifest(
            id: "video-1",
            localID: nil,
            sha256: "sha-video-1",
            path: "VID_0001.MP4",
            filesize: 1024,
            name: "video-1",
            deviceSpace: "device-space-1",
            mediaType: "video",
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: 12.0,
            mimeType: "video/mp4",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(),
            takenAt: Date(),
            clientCTime: nil,
            guessedTakenAt: Date()
        )
        return TimelineItem(original: manifest)
    }

    // Confirms fresh installs default to direct play so videos avoid
    // unnecessary transcoding by default.
    @Test func defaultPlaybackMethodIsDirectPlay() {
        clearPlaybackSettings()
        #expect(PlaybackSettingsManager.shared.playbackMethod == .directPlay)
    }

    // Confirms playback method changes persist through UserDefaults reads so
    // user preferences survive app relaunches.
    @Test func playbackMethodPersistsAcrossReads() {
        clearPlaybackSettings()
        let manager = PlaybackSettingsManager.shared

        manager.playbackMethod = .transcode
        #expect(manager.playbackMethod == .transcode)

        manager.playbackMethod = .directPlay
        #expect(manager.playbackMethod == .directPlay)
    }

    // Confirms settings mutations broadcast notifications so active playback
    // flows can re-evaluate strategy immediately.
    @Test func playbackMethodChangePostsNotification() async {
        clearPlaybackSettings()
        let manager = PlaybackSettingsManager.shared

        let stream = NotificationCenter.default.notifications(
            named: .playbackSettingsDidChange
        )
        let waiter = Task {
            for await _ in stream {
                return true
            }
            return false
        }

        manager.playbackMethod = .transcode
        let didReceive = await waiter.value
        #expect(didReceive)
    }

    // Confirms the temporary strategy selector uses the persisted user
    // preference until bandwidth-based selection is introduced.
    @Test func selectPlaybackMethodReturnsStoredPreference() {
        clearPlaybackSettings()
        let item = makeVideoItem()
        let manager = PlaybackSettingsManager.shared

        manager.playbackMethod = .directPlay
        #expect(PlaybackSettingsManager.selectPlaybackMethod(for: item) == .directPlay)

        manager.playbackMethod = .transcode
        #expect(PlaybackSettingsManager.selectPlaybackMethod(for: item) == .transcode)
    }

    // Confirms production direct play reaches decryptd through gitd's mTLS
    // route rather than a directly exposed service port.
    @Test func makePlaybackURLUsesDecryptdForProductionDirectPlay() throws {
        let url = try FullResolutionImageLoader.makePlaybackURL(
            playbackMethod: .directPlay,
            objectID: "abc123",
            duration: 12,
            isUITesting: false,
            lfsURLString: nil,
            gitURLString: "https://git.example.com:8443/replycant.git"
        )

        #expect(url.absoluteString == "https://git.example.com:8443/decryptd/objects/abc123")
    }

    // Confirms production transcode mode reaches transcoded through gitd too.
    @Test func makePlaybackURLUsesHLSForProductionTranscode() throws {
        let url = try FullResolutionImageLoader.makePlaybackURL(
            playbackMethod: .transcode,
            objectID: "abc123",
            duration: 12,
            isUITesting: false,
            lfsURLString: nil,
            gitURLString: "https://git.example.com:8443/replycant.git"
        )

        #expect(url.absoluteString == "https://git.example.com:8443/transcoded/hls/abc123/12.0/playlist.m3u8")
    }

    // Confirms the libgit2 transport scheme is normalized, since the stored git
    // URL uses mtls+https but URLSession cannot dial that scheme.
    @Test func makePlaybackURLNormalizesMTLSTransportScheme() throws {
        let url = try FullResolutionImageLoader.makePlaybackURL(
            playbackMethod: .directPlay,
            objectID: "abc123",
            duration: 12,
            isUITesting: false,
            lfsURLString: nil,
            gitURLString: "mtls+https://git.example.com:8443/replycant.git"
        )

        #expect(url.absoluteString == "https://git.example.com:8443/decryptd/objects/abc123")
    }

    // Confirms UI tests can validate direct-play behavior against the local test server.
    @Test func makePlaybackURLUsesObjectRouteForUITestDirectPlay() throws {
        let url = try FullResolutionImageLoader.makePlaybackURL(
            playbackMethod: .directPlay,
            objectID: "abc123",
            duration: 12,
            isUITesting: true,
            lfsURLString: "http://localhost:4242/lfs",
            gitURLString: nil
        )

        #expect(url.absoluteString == "http://localhost:4242/objects/abc123")
    }

    // Confirms direct play tells AVFoundation the media type for extensionless decryptd URLs.
    @Test func makePlaybackAssetOptionsAddsMimeTypeForDirectPlay() throws {
        let options = try #require(FullResolutionImageLoader.makePlaybackAssetOptions(
            headerFields: ["X-Replycant-DEK": "dek"],
            mimeType: "video/mp4",
            usesHLS: false
        ))

        let headerFields = try #require(options["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String])
        #expect(headerFields["X-Replycant-DEK"] == "dek")
        #expect(options[FullResolutionImageLoader.playbackMIMETypeAssetOptionKey] as? String == "video/mp4")
    }

    // Confirms HLS keeps normal playlist sniffing instead of forcing a single MIME type.
    @Test func makePlaybackAssetOptionsDoesNotAddMimeTypeForHLS() {
        let options = FullResolutionImageLoader.makePlaybackAssetOptions(
            headerFields: nil,
            mimeType: "video/mp4",
            usesHLS: true
        )

        #expect(options == nil)
    }
}
