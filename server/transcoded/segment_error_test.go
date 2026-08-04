package transcoded

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestHandleSegmentReturnsBadGatewayOnImmediateTranscodeFailure prevents empty 200 segment responses when ffmpeg exits before producing bytes.
func TestHandleSegmentReturnsBadGatewayOnImmediateTranscodeFailure(t *testing.T) {
	upstreamClient := NewUpstreamClient("http://decryptd:8084")
	transcoder := NewTranscoder("false", "ffprobe", upstreamClient)
	server := NewServer(transcoder)

	req := httptest.NewRequest(http.MethodGet, "/hls/48b871c00c0491071d72eb058d978d6e2b391d9915e79e39665a0493d242264d/240p/5.49/segment_0.ts", nil)
	rec := httptest.NewRecorder()

	server.ServeHTTP(rec, req)

	resp := rec.Result()
	defer resp.Body.Close()

	require.Equal(t, http.StatusBadGateway, resp.StatusCode)
	assert.Contains(t, rec.Body.String(), "Failed to transcode segment")
}
