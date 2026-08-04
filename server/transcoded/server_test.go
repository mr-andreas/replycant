package transcoded

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Ensures master playlists advertise the highest-bitrate variant first so
// players configured to start on first eligible variant begin at top quality.
func TestGenerateMasterPlaylistListsHighestBitrateFirst(t *testing.T) {
	transcoder := NewTranscoder("ffmpeg", "ffprobe", nil)
	playlist, err := transcoder.GenerateMasterPlaylist(context.Background(), "abc123", 12.34)
	require.NoError(t, err)

	variantURIs := playlistURIs(playlist)
	require.NotEmpty(t, variantURIs, "master playlist should contain variant URLs")

	highest := DefaultQualityVariants[0]
	for _, candidate := range DefaultQualityVariants[1:] {
		if candidate.Bitrate() > highest.Bitrate() {
			highest = candidate
		}
	}
	assert.Contains(t, variantURIs[0], "/"+highest.Name+"/", "master playlist should list highest bitrate variant first")
}

// Collects the non-comment lines of a playlist, which are its media URIs.
func playlistURIs(playlist string) []string {
	var uris []string
	for _, line := range strings.Split(playlist, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		uris = append(uris, line)
	}
	return uris
}

// Ensures master playlist URIs are relative. gitd serves transcoded under a
// /transcoded prefix and the webapp under /api/transcoded, so absolute paths
// would resolve against the wrong root and 404.
func TestGenerateMasterPlaylistUsesRelativeURIs(t *testing.T) {
	transcoder := NewTranscoder("ffmpeg", "ffprobe", nil)
	playlist, err := transcoder.GenerateMasterPlaylist(context.Background(), "abc123", 12.34)
	require.NoError(t, err)

	base, err := url.Parse("https://git.example:8443/transcoded/hls/abc123/12.34/playlist.m3u8")
	require.NoError(t, err)

	uris := playlistURIs(playlist)
	require.NotEmpty(t, uris)
	for _, uri := range uris {
		require.False(t, strings.HasPrefix(uri, "/"), "variant URI must be relative: %s", uri)
		require.False(t, strings.Contains(uri, "://"), "variant URI must not be absolute: %s", uri)

		reference, err := url.Parse(uri)
		require.NoError(t, err)
		resolved := base.ResolveReference(reference)
		assert.True(
			t,
			strings.HasPrefix(resolved.Path, "/transcoded/hls/abc123/"),
			"variant URI should resolve back under the serving prefix, got %s",
			resolved.Path,
		)
		assert.True(t, strings.HasSuffix(resolved.Path, "/12.34/playlist.m3u8"), "unexpected variant path %s", resolved.Path)
	}
}

// Ensures variant playlists reference segments relatively, for the same
// prefix-independence reason as the master playlist.
func TestGenerateVariantPlaylistUsesRelativeURIs(t *testing.T) {
	transcoder := NewTranscoder("ffmpeg", "ffprobe", nil)
	quality := DefaultQualityVariants[0]
	playlist, err := transcoder.GenerateVariantPlaylist(context.Background(), "abc123", quality, 25.0)
	require.NoError(t, err)

	base, err := url.Parse("https://git.example:8443/transcoded/hls/abc123/" + quality.Name + "/25.00/playlist.m3u8")
	require.NoError(t, err)

	uris := playlistURIs(playlist)
	require.NotEmpty(t, uris)
	for index, uri := range uris {
		require.False(t, strings.HasPrefix(uri, "/"), "segment URI must be relative: %s", uri)

		reference, err := url.Parse(uri)
		require.NoError(t, err)
		resolved := base.ResolveReference(reference)
		assert.Equal(
			t,
			fmt.Sprintf("/transcoded/hls/abc123/%s/25.00/segment_%d.ts", quality.Name, index),
			resolved.Path,
		)
	}
}

// Tests fetching the master playlist from the server using a real upstream server
func TestServerFetchPlaylist(t *testing.T) {
	upstreamURL := os.Getenv("UPSTREAM_URL")
	if upstreamURL == "" {
		upstreamURL = "http://admin:admin@localhost:8080"
	}

	// Use a test hash - this should exist on the upstream server
	// For a real test, you would use a hash that exists on your upstream server
	testHash := os.Getenv("TEST_HASH")
	if testHash == "" {
		// Use a valid hash format - replace with an actual hash from your upstream server
		testHash = "6f634954771ccfae7c7041f12e308e4a658cecdd9020a3a5ac867ef0ac345347"
	}

	upstreamClient := NewUpstreamClient(upstreamURL)
	transcoder := NewTranscoder("ffmpeg", "ffprobe", upstreamClient)
	server := NewServer(transcoder)

	httpServer := httptest.NewServer(server)
	defer httpServer.Close()

	// Test with duration in URL path
	testDuration := "123.45"
	url := httpServer.URL + "/hls/" + testHash + "/" + testDuration + "/playlist.m3u8"
	resp, err := http.Get(url)
	require.NoError(t, err)
	defer resp.Body.Close()

	assert.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, "application/vnd.apple.mpegurl", resp.Header.Get("Content-Type"))

	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)

	playlist := string(body)
	assert.True(t, strings.HasPrefix(playlist, "#EXTM3U"), "Playlist should start with #EXTM3U")
	assert.Contains(t, playlist, "#EXT-X-VERSION:3", "Playlist should contain version")
	assert.Contains(t, playlist, "#EXT-X-STREAM-INF", "Playlist should contain stream info")
	assert.Contains(t, playlist, testDuration, "Playlist should contain duration in variant URLs")
}

// Tests fetching the master playlist from the server using a real upstream server
func TestServerFetchPlaylist240p(t *testing.T) {
	upstreamURL := os.Getenv("UPSTREAM_URL")
	if upstreamURL == "" {
		upstreamURL = "http://admin:admin@localhost:8080"
	}

	// Use a test hash - this should exist on the upstream server
	// For a real test, you would use a hash that exists on your upstream server
	testHash := os.Getenv("TEST_HASH")
	if testHash == "" {
		// Use a valid hash format - replace with an actual hash from your upstream server
		testHash = "01be38a98fb5371c3d5d51110dee1c2c7f1dbecc7afacace41fe6e7db437ef2c"
	}

	upstreamClient := NewUpstreamClient(upstreamURL)
	transcoder := NewTranscoder("ffmpeg", "ffprobe", upstreamClient)
	server := NewServer(transcoder)

	httpServer := httptest.NewServer(server)
	defer httpServer.Close()

	// Test with duration in URL path
	testDuration := "123.45"
	url := httpServer.URL + "/hls/" + testHash + "/720p/" + testDuration + "/playlist.m3u8"
	resp, err := http.Get(url)
	require.NoError(t, err)
	defer resp.Body.Close()

	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, "application/vnd.apple.mpegurl", resp.Header.Get("Content-Type"))

	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)

	playlist := string(body)
	assert.True(t, strings.HasPrefix(playlist, "#EXTM3U"), "Playlist should start with #EXTM3U")
	assert.Contains(t, playlist, "#EXT-X-VERSION:3", "Playlist should contain version")
	assert.Contains(t, playlist, "#EXT-X-TARGETDURATION:11", "Playlist should contain target duration")
	assert.Contains(t, playlist, "#EXT-X-MEDIA-SEQUENCE:0", "Playlist should contain media sequence")
	assert.Contains(t, playlist, "#EXT-X-ENDLIST", "Playlist should contain end list")
	assert.Contains(t, playlist, "segment_0.ts", "Playlist should reference segments relative to its own directory")
}

// Verifies that all variant playlists referenced in the master playlist can be fetched
func TestMasterPlaylistVariantPlaylistsFetchable(t *testing.T) {
	upstreamURL := os.Getenv("UPSTREAM_URL")
	if upstreamURL == "" {
		upstreamURL = "http://admin:admin@localhost:8080"
	}

	testHash := os.Getenv("TEST_HASH")
	if testHash == "" {
		testHash = "6f634954771ccfae7c7041f12e308e4a658cecdd9020a3a5ac867ef0ac345347"
	}

	upstreamClient := NewUpstreamClient(upstreamURL)
	transcoder := NewTranscoder("ffmpeg", "ffprobe", upstreamClient)
	server := NewServer(transcoder)

	httpServer := httptest.NewServer(server)
	defer httpServer.Close()

	testDuration := "123.45"
	masterPlaylistURL := httpServer.URL + "/hls/" + testHash + "/" + testDuration + "/playlist.m3u8"
	
	// Request master playlist
	resp, err := http.Get(masterPlaylistURL)
	require.NoError(t, err)
	defer resp.Body.Close()

	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, "application/vnd.apple.mpegurl", resp.Header.Get("Content-Type"))

	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)

	masterPlaylist := string(body)
	require.True(t, strings.HasPrefix(masterPlaylist, "#EXTM3U"), "Master playlist should start with #EXTM3U")

	variantURLs := playlistURIs(masterPlaylist)
	require.NotEmpty(t, variantURLs, "Master playlist should contain at least one variant playlist URL")

	masterBase, err := url.Parse(masterPlaylistURL)
	require.NoError(t, err)

	// Verify each variant playlist can be fetched
	for _, variantURL := range variantURLs {
		// Variant URIs are relative, so resolve them the way a player would.
		reference, err := url.Parse(variantURL)
		require.NoError(t, err)
		fullURL := masterBase.ResolveReference(reference).String()

		variantResp, err := http.Get(fullURL)
		require.NoError(t, err, "Failed to fetch variant playlist: %s", variantURL)
		defer variantResp.Body.Close()

		assert.Equal(t, http.StatusOK, variantResp.StatusCode, "Variant playlist should return 200 OK: %s", variantURL)
		assert.Equal(t, "application/vnd.apple.mpegurl", variantResp.Header.Get("Content-Type"), "Variant playlist should have correct content type: %s", variantURL)

		variantBody, err := io.ReadAll(variantResp.Body)
		require.NoError(t, err, "Failed to read variant playlist body: %s", variantURL)

		variantPlaylist := string(variantBody)
		assert.True(t, strings.HasPrefix(variantPlaylist, "#EXTM3U"), "Variant playlist should start with #EXTM3U: %s", variantURL)
		assert.Contains(t, variantPlaylist, "#EXT-X-VERSION:3", "Variant playlist should contain version: %s", variantURL)
	}
}
