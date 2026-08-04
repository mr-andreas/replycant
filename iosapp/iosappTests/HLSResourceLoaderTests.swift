import Foundation
import Testing
@testable import iosapp

// Covers the URL and header mapping HLSResourceLoader performs on every
// AVFoundation sub-request. This mapping is the whole reason the loader exists:
// transcoded sits behind gitd's mTLS endpoint, which AVPlayer cannot reach on
// its own, so playlists must be handed to AVPlayer under a custom scheme and
// translated back to https here.
struct HLSResourceLoaderTests {

    // Confirms the playlist handed to AVPlayer is moved onto the custom scheme,
    // which is what causes AVFoundation to route sub-requests to this loader.
    @Test func customSchemeURLRewritesScheme() throws {
        let httpURL = try #require(URL(string: "https://git.example:8443/transcoded/hls/abc/12.0/playlist.m3u8"))
        let customURL = try #require(HLSResourceLoader.customSchemeURL(from: httpURL))

        #expect(customURL.absoluteString == "replycant-hls://git.example:8443/transcoded/hls/abc/12.0/playlist.m3u8")
    }

    // Confirms relative playlist URIs resolved by AVFoundation map back to the
    // correct https URL. transcoded emits relative URIs precisely so this
    // round-trip needs no playlist body rewriting.
    @Test func httpURLRestoresHTTPSForResolvedSubRequests() throws {
        let variantURL = try #require(URL(string: "replycant-hls://git.example:8443/transcoded/hls/abc/720p/12.0/segment_3.ts"))
        let restored = try #require(HLSResourceLoader.httpURL(from: variantURL))

        #expect(restored.absoluteString == "https://git.example:8443/transcoded/hls/abc/720p/12.0/segment_3.ts")
    }

    // Guards against translating URLs that never belonged to this loader.
    @Test func httpURLRejectsForeignSchemes() throws {
        let foreignURL = try #require(URL(string: "https://git.example:8443/transcoded/hls/abc/12.0/playlist.m3u8"))

        #expect(HLSResourceLoader.httpURL(from: foreignURL) == nil)
    }

    // AVFoundation never sees the real URL extension, so the loader must declare
    // the media type explicitly or playlist parsing fails.
    @Test func contentTypeMapsPlaylistsAndSegments() throws {
        let playlist = try #require(URL(string: "replycant-hls://git.example/transcoded/hls/abc/12.0/playlist.m3u8"))
        let segment = try #require(URL(string: "replycant-hls://git.example/transcoded/hls/abc/720p/12.0/segment_0.ts"))
        let unknown = try #require(URL(string: "replycant-hls://git.example/transcoded/hls/abc/notes.txt"))

        #expect(HLSResourceLoader.contentType(for: playlist) == "public.m3u8-playlist")
        #expect(HLSResourceLoader.contentType(for: segment) == "public.mpeg-2-transport-stream")
        #expect(HLSResourceLoader.contentType(for: unknown) == nil)
    }

    // Confirms DEK headers ride along on every sub-request, since transcoded
    // pulls plaintext from decryptd using the request-scoped key.
    @Test func makeRequestAttachesDecryptionHeaders() throws {
        let customURL = try #require(URL(string: "replycant-hls://git.example:8443/transcoded/hls/abc/12.0/playlist.m3u8"))
        let request = try #require(
            HLSResourceLoader.makeRequest(
                for: customURL,
                headers: ["X-Replycant-DEK": "dek-value"]
            )
        )

        #expect(request.url?.scheme == "https")
        #expect(request.value(forHTTPHeaderField: "X-Replycant-DEK") == "dek-value")
        #expect(request.value(forHTTPHeaderField: "X-Replycant-Chunk-Size") == nil)
    }

    // The loader advertises byte-range support and issues ranged sub-requests, so
    // a 206 must still report the size of the whole resource. Reporting the slice
    // size instead makes AVFoundation treat the first slice as the entire asset
    // and misjudge the resource boundaries.
    @Test func contentLengthPrefersContentRangeTotalOverPartialSize() throws {
        let response = try Self.makeResponse(
            statusCode: 206,
            headers: ["Content-Range": "bytes 0-99/1000", "Content-Length": "100"]
        )

        #expect(HLSResourceLoader.contentLength(from: response) == 1000)
    }

    // Unranged responses carry the full size in Content-Length alone.
    @Test func contentLengthFallsBackToContentLength() throws {
        let response = try Self.makeResponse(statusCode: 200, headers: ["Content-Length": "500"])

        #expect(HLSResourceLoader.contentLength(from: response) == 500)
    }

    // Absent size metadata must not be inferred from the payload, since that is
    // exactly the guess that misreports partial responses as complete ones.
    @Test func contentLengthIsZeroWithoutSizeHeaders() throws {
        let response = try Self.makeResponse(statusCode: 200, headers: [:])

        #expect(HLSResourceLoader.contentLength(from: response) == 0)
    }

    // Builds upstream response fixtures for the content-length assertions above.
    private static func makeResponse(statusCode: Int, headers: [String: String]) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://git.example:8443/transcoded/hls/abc/720p/12.0/segment_0.ts"))
        return try #require(
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)
        )
    }
}
