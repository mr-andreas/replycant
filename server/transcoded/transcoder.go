package transcoded

import (
	"context"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

var argSets = map[string]func(url string, startTime float64, segmentDuration float64, quality QualityVariant, headers string) []string{
	// "Nvidia 10bit GPU": func(url string, startTime float64, segmentDuration float64, quality QualityVariant) []string {
	// 	return []string{
	// 		"-hwaccel", "cuda",
	// 		"-hwaccel_output_format", "cuda",
	// 		"-headers", "Accept: application/vnd.git-lfs",
	// 		"-ss", fmt.Sprintf("%.3f", startTime),
	// 		"-i", url,
	// 		"-t", fmt.Sprintf("%.3f", segmentDuration),
	// 		"-output_ts_offset", fmt.Sprintf("%.3f", startTime),
	// 		"-vf", fmt.Sprintf("scale_cuda=%d:%d:format=p010le", quality.Width, quality.Height),
	// 		"-c:v", "hevc_nvenc",
	// 		"-preset", "p1",
	// 		"-maxrate", fmt.Sprintf("%d", quality.Bitrate),
	// 		"-cq", "23",
	// 		"-c:a", "aac",
	// 		"-b:a", fmt.Sprintf("%d", quality.AudioBitrate),
	// 		"-f", "mpegts",
	// 		"-probesize", "10000000",
	// 		"-analyzeduration", "10000000",
	// 		"-nostdin",
	// 		"-",
	// 	}
	// },

	"Nvidia 8bit GPU fast": func(url string, startTime float64, segmentDuration float64, quality QualityVariant, headers string) []string {
		// Provides ffmpeg flags for Nvidia GPU in 8-bit mode (yuv420p) to maximize compatibility and hardware acceleration for streaming lower-bitrate variants.
		return []string{
			"-hwaccel", "cuda",
			"-hwaccel_output_format", "cuda",
			"-headers", headers,
			"-ss", fmt.Sprintf("%.3f", startTime),
			"-i", url,
			"-t", fmt.Sprintf("%.3f", segmentDuration),
			"-output_ts_offset", fmt.Sprintf("%.3f", startTime),
			"-vf", fmt.Sprintf("scale_cuda=%d:%d:format=yuv420p,hwdownload", -2, quality.Height),
			"-c:v", "h264_nvenc",
			"-preset", "p1",
			"-maxrate", fmt.Sprintf("%d", quality.VideoBitrate),
			"-bufsize", fmt.Sprintf("%d", quality.VideoBitrate*2),
			"-cq", "23",
			"-c:a", "aac",
			"-b:a", fmt.Sprintf("%d", quality.AudioBitrate),
			"-map_metadata", "0",
			"-f", "mpegts",
			"-probesize", "10000000",
			"-analyzeduration", "10000000",
			"-nostdin",
			"-",
		}
	},

	"Nvidia 8bit GPU quality": func(url string, startTime float64, segmentDuration float64, quality QualityVariant, headers string) []string {
		// Provides ffmpeg flags for Nvidia GPU in 8-bit mode (yuv420p) to maximize compatibility and hardware acceleration for streaming lower-bitrate variants.
		return []string{
			"-hwaccel", "cuda",
			"-hwaccel_output_format", "cuda",
			"-headers", headers,
			"-ss", fmt.Sprintf("%.3f", startTime),
			"-i", url,
			"-t", fmt.Sprintf("%.3f", segmentDuration),
			"-output_ts_offset", fmt.Sprintf("%.3f", startTime),
			"-vf", fmt.Sprintf("scale_cuda=%d:%d:format=yuv420p,hwdownload", -2, quality.Height),
			"-c:v", "h264_nvenc",
			"-preset", "p7",
			"-rc", "vbr",
			"-spatial-aq", "1",
			"-maxrate", fmt.Sprintf("%d", quality.VideoBitrate),
			"-bufsize", fmt.Sprintf("%d", quality.VideoBitrate*2),
			"-cq", "15",
			"-c:a", "aac",
			"-b:a", fmt.Sprintf("%d", quality.AudioBitrate),
			"-profile:a", "aac_low",
			"-ar", "48000",
			"-ac", "2",
			"-map_metadata", "0",
			"-movflags", "faststart",
			"-f", "mpegts",
			// "-probesize", "10000000",
			// "-analyzeduration", "10000000",
			"-nostdin",
			"-",
		}
	},

	"Raspberry Pi 5": func(url string, startTime float64, segmentDuration float64, quality QualityVariant, headers string) []string {
		// Pi 5 has no hardware H.264 encoder (VideoCore VII only
		// exposes an HEVC decoder via V4L2). Uses libx264 software
		// encoding with ultrafast preset to keep up on the quad
		// Cortex-A76.
		return []string{
			"-headers", headers,
			"-ss", fmt.Sprintf("%.3f", startTime),
			"-i", url,
			"-t", fmt.Sprintf("%.3f", segmentDuration),
			"-output_ts_offset", fmt.Sprintf("%.3f", startTime),
			"-vf", fmt.Sprintf("scale=%d:%d", -2, quality.Height),
			"-c:v", "libx264",
			"-preset", "ultrafast",
			"-tune", "zerolatency",
			"-crf", "23",
			"-maxrate", fmt.Sprintf("%d", quality.VideoBitrate),
			"-bufsize", fmt.Sprintf("%d", quality.VideoBitrate*2),
			"-c:a", "aac",
			"-b:a", fmt.Sprintf("%d", quality.AudioBitrate),
			"-threads", "3",
			"-map_metadata", "0",
			"-f", "mpegts",
			"-nostdin",
			"-",
		}
	},
}

var argSet = argSets["Raspberry Pi 5"]

const (
	K = 1000
	M = 1000 * K
)

// Quality variant configuration for adaptive bitrate HLS
type QualityVariant struct {
	Name         string
	Width        int
	Height       int
	VideoBitrate int
	AudioBitrate int
}

func (q *QualityVariant) Bitrate() int {
	br := float64(q.VideoBitrate + q.AudioBitrate)
	br *= 1.1 // 10% overhead for container formats etc
	return int(br)
}

// Standard quality variants for adaptive bitrate streaming
var DefaultQualityVariants = []QualityVariant{
	{"240p", 426, 240, 800 * K, 64000},
	{"360p", 640, 360, 1200 * K, 96000},
	{"480p", 854, 480, 2500 * K, 128000},
	{"720p", 1280, 720, 5 * M, 128000},
	{"1080p", 1920, 1080, 8 * M, 128000},
	{"1440p", 2560, 1440, 16 * M, 128000},
	{"2160p", 3840, 2160, 40 * M, 128000},
}

// Manages on-the-fly ffmpeg transcoding for HLS
type Transcoder struct {
	ffmpegPath  string
	ffprobePath string
	upstream    *UpstreamClient
}

// Creates a new transcoder with the specified ffmpeg path and upstream client
func NewTranscoder(ffmpegPath string, ffprobePath string, upstream *UpstreamClient) *Transcoder {
	return &Transcoder{
		ffmpegPath:  ffmpegPath,
		ffprobePath: ffprobePath,
		upstream:    upstream,
	}
}

// Generates master playlist with all quality variants.
// Variant URIs are relative because transcoded is reached through several
// different prefixes (gitd's /transcoded, the webapp's /api/transcoded, and the
// iOS custom playback scheme); absolute paths would resolve against the wrong
// root under all but a bare deployment.
func (t *Transcoder) GenerateMasterPlaylist(ctx context.Context, hash string, duration float64) (string, error) {
	var builder strings.Builder
	builder.WriteString("#EXTM3U\n")
	builder.WriteString("#EXT-X-VERSION:3\n")

	sortedVariants := make([]QualityVariant, len(DefaultQualityVariants))
	copy(sortedVariants, DefaultQualityVariants)
	sort.Slice(sortedVariants, func(i int, j int) bool {
		return sortedVariants[i].Bitrate() > sortedVariants[j].Bitrate()
	})

	for _, variant := range sortedVariants {
		// Relative to /hls/{hash}/{duration}/, where the master playlist lives.
		playlistURL := fmt.Sprintf("../%s/%.2f/playlist.m3u8", variant.Name, duration)
		builder.WriteString(fmt.Sprintf("#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%dx%d\n", variant.Bitrate(), variant.Width, variant.Height))
		builder.WriteString(playlistURL)
		builder.WriteByte('\n')
	}

	return builder.String(), nil
}

// Generates variant playlist for a specific quality. Returns the playlist content.
// Segment URIs are relative for the same prefix-independence reason as the
// master playlist.
func (t *Transcoder) GenerateVariantPlaylist(ctx context.Context, hash string, quality QualityVariant, duration float64) (string, error) {
	log.Printf("Generating variant playlist for hash: %s, quality: %s, duration: %.2f seconds", hash, quality.Name, duration)

	segmentDuration := 10.0
	numSegments := int(duration / segmentDuration)
	if numSegments == 0 {
		numSegments = 1
	}
	log.Printf("Generating variant playlist for hash: %s, quality: %s with %d segments", hash, quality.Name, numSegments)

	var builder strings.Builder
	builder.WriteString("#EXTM3U\n")
	builder.WriteString("#EXT-X-VERSION:3\n")
	builder.WriteString(fmt.Sprintf("#EXT-X-TARGETDURATION:%d\n", int(segmentDuration)+1))
	builder.WriteString("#EXT-X-MEDIA-SEQUENCE:0\n")

	for i := 0; i < numSegments; i++ {
		// Relative to the variant playlist's own directory.
		segmentURL := fmt.Sprintf("segment_%d.ts", i)
		builder.WriteString(fmt.Sprintf("#EXTINF:%.3f,\n", segmentDuration))
		builder.WriteString(segmentURL)
		builder.WriteByte('\n')
	}

	builder.WriteString("#EXT-X-ENDLIST\n")

	return builder.String(), nil
}

// Transcodes a specific segment on-the-fly and streams it to the provided writer
func (t *Transcoder) TranscodeSegment(ctx context.Context, hash string, quality QualityVariant, segmentNum int, decryptHeaders *DecryptionHeaders, w io.Writer) error {
	segmentDuration := 10.0
	startTime := float64(segmentNum) * segmentDuration

	// Let FFmpeg fetch directly from upstream URL with HTTP Range support
	// This allows FFmpeg to seek as needed for MOV files without caching to disk
	upstreamURL := t.upstream.GetObjectURL(hash)
	log.Printf("Transcoding from upstream URL: %s", upstreamURL)

	ffmpegHeaders := t.upstream.GetHeaders(decryptHeaders)
	args := argSet(upstreamURL, startTime, segmentDuration, quality, ffmpegHeaders)

	log.Printf("Starting ffmpeg transcoding for hash: %s, segment: %d, quality: %s, startTime: %.2fs", hash, segmentNum, quality.Name, startTime)
	log.Printf("DEBUG: ffmpeg command: %s %s", t.ffmpegPath, sanitizeArgsForLog(args))
	cmd := exec.CommandContext(ctx, t.ffmpegPath, args...)

	// Capture stderr to see if ffmpeg has any errors
	var stderrBuf strings.Builder
	cmd.Stderr = &stderrBuf
	cmd.Stdout = w

	transcodeStart := time.Now()
	if err := cmd.Start(); err != nil {
		log.Printf("ERROR: Failed to start ffmpeg for hash: %s, segment: %d, quality: %s: %v", hash, segmentNum, quality.Name, err)
		return &TranscodingError{Hash: hash, Err: err}
	}

	err := cmd.Wait()
	stderrOutput := stderrBuf.String()

	// Only fail if ffmpeg actually returned an error AND produced no output
	// Warnings about "partial file" are expected when streaming MOV files
	if err != nil {
		// Check if it's just warnings or a real error
		if strings.Contains(stderrOutput, "Output file is empty") {
			log.Printf("ERROR: ffmpeg produced no output for hash: %s, segment: %d, quality: %s", hash, segmentNum, quality.Name)
			if stderrOutput != "" {
				log.Printf("ERROR: ffmpeg stderr output: %s", stderrOutput)
			}
			return &TranscodingError{Hash: hash, Err: fmt.Errorf("ffmpeg produced no output")}
		}
		log.Printf("ERROR: ffmpeg transcoding failed for hash: %s, segment: %d, quality: %s: %v (took %v)", hash, segmentNum, quality.Name, err, time.Since(transcodeStart))
		if stderrOutput != "" {
			log.Printf("ERROR: ffmpeg stderr output: %s", stderrOutput)
		}
		return &TranscodingError{Hash: hash, Err: err}
	}

	// Even if ffmpeg exits successfully, check if it actually produced output
	if strings.Contains(stderrOutput, "Output file is empty") && !strings.Contains(stderrOutput, "frame=") {
		log.Printf("ERROR: ffmpeg produced no output for hash: %s, segment: %d, quality: %s", hash, segmentNum, quality.Name)
		if stderrOutput != "" {
			log.Printf("ERROR: ffmpeg stderr output: %s", stderrOutput)
		}
		return &TranscodingError{Hash: hash, Err: fmt.Errorf("ffmpeg produced no output")}
	}

	log.Printf("ffmpeg transcoding completed for hash: %s, segment: %d, quality: %s (took %v)", hash, segmentNum, quality.Name, time.Since(transcodeStart))

	return nil
}

// Gets video duration in seconds by probing the upstream object
func (t *Transcoder) getVideoDuration(ctx context.Context, hash string) (float64, error) {
	// Let FFmpeg fetch directly from upstream URL with HTTP Range support
	upstreamURL := t.upstream.GetObjectURL(hash)
	log.Printf("Probing video duration from upstream URL: %s", upstreamURL)

	args := []string{}

	// Add HTTP headers (Accept and Authorization if configured)
	headers := t.upstream.GetHeaders(nil)
	if headers != "" {
		args = append(args, "-headers", headers)
	}

	args = append(args,
		"-i", upstreamURL,
	)

	log.Printf("Running ffprobe to get video duration, hash: %s", hash)
	argsStr := ""
	for _, arg := range args {
		argsStr += fmt.Sprintf("%q ", arg)
	}
	log.Printf("DEBUG: ffprobe command: %s %s", t.ffprobePath, argsStr)
	cmd := exec.CommandContext(ctx, t.ffprobePath, args...)
	output, err := cmd.CombinedOutput()

	outputStr := string(output)
	duration, parseErr := parseDurationFromFFmpeg(outputStr)
	if parseErr != nil {
		if err != nil {
			log.Printf("ERROR: ffprobe probe failed for hash: %s: %v", hash, err)
			return 0, fmt.Errorf("ffprobe failed: %w (output: %s)", err, outputStr)
		}
		log.Printf("ERROR: Failed to parse duration from ffprobe output for hash: %s", hash)
		return 0, fmt.Errorf("failed to parse duration: %w (output: %s)", parseErr, outputStr)
	}

	return duration, nil
}

// Parses duration from ffmpeg output (looks for "Duration: HH:MM:SS.mmm")
func parseDurationFromFFmpeg(output string) (float64, error) {
	lines := strings.Split(output, "\n")
	for _, line := range lines {
		if strings.Contains(line, "Duration:") {
			parts := strings.Split(line, "Duration:")
			if len(parts) < 2 {
				continue
			}
			durationStr := strings.TrimSpace(strings.Split(parts[1], ",")[0])
			return parseDuration(durationStr)
		}
	}
	return 0, fmt.Errorf("duration not found in ffmpeg output")
}

// Parses duration string in format HH:MM:SS.mmm to seconds
func parseDuration(durationStr string) (float64, error) {
	parts := strings.Split(durationStr, ":")
	if len(parts) != 3 {
		return 0, fmt.Errorf("invalid duration format: %s", durationStr)
	}

	hours, err := strconv.ParseFloat(parts[0], 64)
	if err != nil {
		return 0, err
	}

	minutes, err := strconv.ParseFloat(parts[1], 64)
	if err != nil {
		return 0, err
	}

	seconds, err := strconv.ParseFloat(parts[2], 64)
	if err != nil {
		return 0, err
	}

	return hours*3600 + minutes*60 + seconds, nil
}

// Converts bitrate string (e.g., "400k") to integer
func (t *Transcoder) bitrateToInt(bitrate string) int {
	bitrate = strings.ToLower(bitrate)
	if strings.HasSuffix(bitrate, "k") {
		val, _ := strconv.Atoi(strings.TrimSuffix(bitrate, "k"))
		return val
	}
	if strings.HasSuffix(bitrate, "m") {
		val, _ := strconv.Atoi(strings.TrimSuffix(bitrate, "m"))
		return val * 1000
	}
	val, _ := strconv.Atoi(bitrate)
	return val
}

// sanitizeArgsForLog removes sensitive header values from ffmpeg debug output.
func sanitizeArgsForLog(args []string) string {
	redacted := make([]string, len(args))
	copy(redacted, args)
	for i := 0; i < len(redacted)-1; i++ {
		if redacted[i] == "-headers" {
			redacted[i+1] = "[REDACTED_HEADERS]"
		}
	}
	return strings.Join(redacted, " ")
}
