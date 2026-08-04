package transcoded

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// HTTP server for serving HLS streams
type Server struct {
	transcoder *Transcoder
	mux        *http.ServeMux
}

const (
	// HeaderDEK carries the per-request base64-encoded DEK for decryptd.
	HeaderDEK = "X-Replycant-DEK"
)

// DecryptionHeaders carries validated request-scoped values needed by decryptd.
type DecryptionHeaders struct {
	DEK string
}

// Creates a new HLS server with the specified transcoder
func NewServer(transcoder *Transcoder) *Server {
	s := &Server{
		transcoder: transcoder,
		mux:        http.NewServeMux(),
	}

	s.mux.HandleFunc("/hls/", s.handleHLS)

	return s
}

// Serves HTTP requests
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	setCORSHeaders(w)

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		logCommonLogFormat(r, http.StatusOK, 0)
		return
	}

	start := time.Now()
	s.mux.ServeHTTP(w, r)
	duration := time.Since(start)

	log.Printf("[%s] %s %s completed in %v", r.Method, r.URL.Path, getRequestType(r.URL.Path), duration)
}

// Handles HLS requests: master playlist, variant playlists, and segments
func (s *Server) handleHLS(w http.ResponseWriter, r *http.Request) {
	requestStart := time.Now()

	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/hls/")
	parts := strings.Split(path, "/")

	if len(parts) < 2 {
		http.Error(w, "Invalid path", http.StatusBadRequest)
		return
	}

	hash := parts[0]
	if !isValidHash(hash) {
		http.Error(w, fmt.Sprintf("Invalid hash: %s", hash), http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()

	// Master playlist: /hls/{hash}/{duration}/playlist.m3u8
	if len(parts) == 3 && parts[2] == "playlist.m3u8" {
		duration, err := parseDurationFromPath(parts[1])
		if err != nil {
			http.Error(w, fmt.Sprintf("Invalid duration: %v", err), http.StatusBadRequest)
			return
		}
		s.handleMasterPlaylist(ctx, w, r, hash, duration)
		return
	}

	// Variant playlist: /hls/{hash}/{quality}/{duration}/playlist.m3u8
	if len(parts) == 4 && parts[3] == "playlist.m3u8" {
		quality := findQualityVariant(parts[1])
		if quality == nil {
			http.Error(w, fmt.Sprintf("Invalid quality: %s", parts[1]), http.StatusBadRequest)
			return
		}
		duration, err := parseDurationFromPath(parts[2])
		if err != nil {
			http.Error(w, fmt.Sprintf("Invalid duration: %v", err), http.StatusBadRequest)
			return
		}
		s.handleVariantPlaylist(ctx, w, r, hash, *quality, duration)
		return
	}

	// Segment: /hls/{hash}/{quality}/{duration}/segment_{i}.ts
	if len(parts) == 4 && strings.HasPrefix(parts[3], "segment_") {
		quality := findQualityVariant(parts[1])
		if quality == nil {
			http.Error(w, fmt.Sprintf("Invalid quality: %s", parts[1]), http.StatusBadRequest)
			return
		}
		duration, err := parseDurationFromPath(parts[2])
		if err != nil {
			http.Error(w, fmt.Sprintf("Invalid duration: %v", err), http.StatusBadRequest)
			return
		}
		log.Printf("findQualityVariant %v", time.Since(requestStart))

		segmentNum, err := parseSegmentNumber(parts[3])
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		s.handleSegment(ctx, w, r, hash, *quality, segmentNum, duration)
		log.Printf("handleSegment %v", time.Since(requestStart))
		return
	}

	http.Error(w, "Invalid path", http.StatusBadRequest)
}

// Sets CORS headers to allow all origins
func setCORSHeaders(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Range, Content-Type, "+HeaderDEK)
	w.Header().Set("Access-Control-Expose-Headers", "Content-Length, Content-Range")
}

// Handles master playlist request
func (s *Server) handleMasterPlaylist(ctx context.Context, w http.ResponseWriter, r *http.Request, hash string, duration float64) {
	log.Printf("Generating master playlist for hash: %s, duration: %.2f", hash, duration)
	playlist, err := s.transcoder.GenerateMasterPlaylist(ctx, hash, duration)
	if err != nil {
		log.Printf("ERROR: Failed to generate master playlist for hash %s: %v", hash, err)
		http.Error(w, fmt.Sprintf("Failed to generate master playlist: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(playlist))
	log.Printf("Master playlist generated for hash: %s (%d bytes)", hash, len(playlist))
}

// Handles variant playlist request
func (s *Server) handleVariantPlaylist(ctx context.Context, w http.ResponseWriter, r *http.Request, hash string, quality QualityVariant, duration float64) {
	log.Printf("Generating variant playlist for hash: %s, quality: %s, duration: %.2f", hash, quality.Name, duration)
	playlist, err := s.transcoder.GenerateVariantPlaylist(ctx, hash, quality, duration)
	if err != nil {
		log.Printf("ERROR: Failed to generate variant playlist for hash %s, quality %s: %v", hash, quality.Name, err)
		http.Error(w, fmt.Sprintf("Failed to generate variant playlist: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(playlist))
	log.Printf("Variant playlist generated for hash: %s, quality: %s (%d bytes)", hash, quality.Name, len(playlist))
}

// Handles segment request with Range header support for seeking
func (s *Server) handleSegment(ctx context.Context, w http.ResponseWriter, r *http.Request, hash string, quality QualityVariant, segmentNum int, duration float64) {
	requestStart := time.Now()
	if segmentNum < 0 {
		log.Printf("ERROR: Invalid segment number: %d for hash: %s", segmentNum, hash)
		http.Error(w, "Invalid segment number", http.StatusBadRequest)
		return
	}

	decryptionHeaders, hasDecryptionHeaders, err := parseDecryptionHeaders(r)
	if err != nil {
		http.Error(w, "Invalid decryption headers", http.StatusBadRequest)
		return
	}

	rangeHeader := r.Header.Get("Range")
	rangeStart, rangeEnd, hasRange := parseRangeHeader(rangeHeader)
	if hasRange {
		log.Printf("Transcoding segment %d for hash: %s, quality: %s (Range: %s, parsed: %d-%d)", segmentNum, hash, quality.Name, rangeHeader, rangeStart, rangeEnd)
	} else if rangeHeader != "" {
		log.Printf("Transcoding segment %d for hash: %s, quality: %s (Invalid Range: %s)", segmentNum, hash, quality.Name, rangeHeader)
	} else {
		log.Printf("Transcoding segment %d for hash: %s, quality: %s", segmentNum, hash, quality.Name)
	}

	// Use a pipe to buffer output and verify transcoding can start before writing headers
	pipeReader, pipeWriter := io.Pipe()
	transcodeErrChan := make(chan error, 1)

	// Start transcoding in a goroutine
	go func() {
		defer pipeWriter.Close()
		err := s.transcoder.TranscodeSegment(ctx, hash, quality, segmentNum, decryptionHeadersOrNil(decryptionHeaders, hasDecryptionHeaders), pipeWriter)
		transcodeErrChan <- err
	}()

	// Read first chunk to verify transcoding started successfully
	firstChunk := make([]byte, 4096)
	n, readErr := pipeReader.Read(firstChunk)
	if readErr != nil && readErr != io.EOF {
		log.Printf("ERROR: Failed to read first chunk for segment %d, hash: %s, quality: %s: %v", segmentNum, hash, quality.Name, readErr)
		pipeReader.Close()
		// Wait for transcoding to finish to avoid goroutine leak
		transcodeErr := <-transcodeErrChan
		if transcodeErr != nil {
			log.Printf("ERROR: Failed to transcode segment %d for hash: %s, quality: %s: %v", segmentNum, hash, quality.Name, transcodeErr)
		}
		if ctx.Err() == context.DeadlineExceeded {
			http.Error(w, "Request timeout", http.StatusRequestTimeout)
			return
		}
		http.Error(w, "Failed to transcode segment", http.StatusBadGateway)
		return
	}
	if n == 0 && readErr == io.EOF {
		log.Printf("ERROR: Transcoding produced no output for segment %d, hash: %s, quality: %s", segmentNum, hash, quality.Name)
		pipeReader.Close()
		transcodeErr := <-transcodeErrChan
		if transcodeErr != nil {
			log.Printf("ERROR: Failed to transcode segment %d for hash: %s, quality: %s: %v", segmentNum, hash, quality.Name, transcodeErr)
		}
		if ctx.Err() == context.DeadlineExceeded {
			http.Error(w, "Request timeout", http.StatusRequestTimeout)
			return
		}
		http.Error(w, "Failed to transcode segment", http.StatusBadGateway)
		return
	}

	// If Range header is present, buffer entire segment first to determine size
	if hasRange {
		// Buffer the entire segment
		var buf bytes.Buffer
		if n > 0 {
			buf.Write(firstChunk[:n])
		}
		_, copyErr := io.Copy(&buf, pipeReader)
		pipeReader.Close()

		// Wait for transcoding to complete
		transcodeErr := <-transcodeErrChan
		if transcodeErr != nil {
			log.Printf("ERROR: Failed to transcode segment %d for hash: %s, quality: %s: %v", segmentNum, hash, quality.Name, transcodeErr)
			if ctx.Err() == context.DeadlineExceeded {
				http.Error(w, "Request timeout", http.StatusRequestTimeout)
			} else {
				http.Error(w, fmt.Sprintf("Failed to transcode segment: %v", transcodeErr), http.StatusInternalServerError)
			}
			return
		}
		if copyErr != nil {
			log.Printf("ERROR: Failed to buffer segment %d for hash: %s, quality: %s: %v", segmentNum, hash, quality.Name, copyErr)
			http.Error(w, fmt.Sprintf("Failed to buffer segment: %v", copyErr), http.StatusInternalServerError)
			return
		}

		totalSize := int64(buf.Len())
		actualEnd := rangeEnd
		if actualEnd == -1 || actualEnd >= totalSize {
			actualEnd = totalSize - 1
		}

		// Validate range
		if rangeStart >= totalSize || rangeStart > actualEnd {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", totalSize))
			http.Error(w, "Range Not Satisfiable", http.StatusRequestedRangeNotSatisfiable)
			return
		}

		// Set headers for 206 Partial Content
		w.Header().Set("Content-Type", "video/mp2t")
		w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", rangeStart, actualEnd, totalSize))
		w.Header().Set("Content-Length", fmt.Sprintf("%d", actualEnd-rangeStart+1))
		w.WriteHeader(http.StatusPartialContent)
		log.Printf("writeHeader (206 Partial Content) %v", time.Since(requestStart))

		// Write the requested range
		segmentData := buf.Bytes()
		if _, err := w.Write(segmentData[rangeStart : actualEnd+1]); err != nil {
			log.Printf("ERROR: Failed to write range for segment %d, hash: %s, quality: %s: %v", segmentNum, hash, quality.Name, err)
			return
		}

		elapsed := time.Since(requestStart)
		log.Printf("Segment %d range %d-%d served successfully for hash: %s, quality: %s (duration: %v)", segmentNum, rangeStart, actualEnd, hash, quality.Name, elapsed)
		return
	}

	// No Range header - stream the segment normally
	// Only write headers after confirming transcoding can produce output
	w.Header().Set("Content-Type", "video/mp2t")
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	w.Header().Set("Accept-Ranges", "bytes")
	w.WriteHeader(http.StatusOK)
	log.Printf("writeHeader %v", time.Since(requestStart))

	// Write the first chunk
	if n > 0 {
		if _, err := w.Write(firstChunk[:n]); err != nil {
			log.Printf("ERROR: Failed to write first chunk for segment %d, hash: %s, quality: %s: %v", segmentNum, hash, quality.Name, err)
			pipeReader.Close()
			<-transcodeErrChan
			return
		}
		// Flush to start streaming immediately
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
	}

	start := time.Now()
	// Copy the rest of the data
	_, copyErr := io.Copy(w, pipeReader)
	pipeReader.Close()

	// Wait for transcoding to complete and check for errors
	transcodeErr := <-transcodeErrChan
	if transcodeErr != nil {
		elapsed := time.Since(start)
		log.Printf("transcodeSegment %v", time.Since(requestStart))
		if ctx.Err() == context.DeadlineExceeded {
			log.Printf("ERROR: Transcoding timeout for segment %d, hash: %s, quality: %s (duration: %v)", segmentNum, hash, quality.Name, elapsed)
			return
		}
		log.Printf("ERROR: Failed to transcode segment %d for hash: %s, quality: %s: %v (duration: %v)", segmentNum, hash, quality.Name, transcodeErr, elapsed)
		return
	}

	if copyErr != nil {
		log.Printf("ERROR: Failed to copy segment data for segment %d, hash: %s, quality: %s: %v", segmentNum, hash, quality.Name, copyErr)
		return
	}

	// Flush the response to ensure all data is sent
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}

	elapsed := time.Since(start)
	log.Printf("Segment %d transcoded successfully for hash: %s, quality: %s (duration: %v)", segmentNum, hash, quality.Name, elapsed)
}

// parseDecryptionHeaders enforces encrypted playback header validation.
// Chunk size is a compile-time constant shared with decryptd, so it is not a request header.
func parseDecryptionHeaders(r *http.Request) (headers DecryptionHeaders, present bool, err error) {
	dek := strings.TrimSpace(r.Header.Get(HeaderDEK))
	if dek == "" {
		return DecryptionHeaders{}, false, nil
	}

	decoded, decodeErr := base64.StdEncoding.DecodeString(dek)
	if decodeErr != nil || len(decoded) != 32 {
		return DecryptionHeaders{}, false, fmt.Errorf("invalid dek header")
	}

	return DecryptionHeaders{DEK: dek}, true, nil
}

// decryptionHeadersOrNil keeps plain-media paths unchanged when no key material is provided.
func decryptionHeadersOrNil(headers DecryptionHeaders, present bool) *DecryptionHeaders {
	if !present {
		return nil
	}
	return &headers
}

// Validates SHA256 hash format (64 hex characters)
func isValidHash(hash string) bool {
	matched, _ := regexp.MatchString("^[0-9a-f]{64}$", hash)
	return matched
}

// Finds quality variant by name
func findQualityVariant(name string) *QualityVariant {
	for _, variant := range DefaultQualityVariants {
		if variant.Name == name {
			return &variant
		}
	}
	return nil
}

// Parses HTTP Range header (e.g., "bytes=0-1023" or "bytes=1024-")
// Returns start, end, and whether a valid range was specified
// end will be -1 if range extends to end of file
func parseRangeHeader(rangeHeader string) (start int64, end int64, valid bool) {
	if rangeHeader == "" {
		return 0, -1, false
	}

	// Range header format: "bytes=start-end" or "bytes=start-"
	if !strings.HasPrefix(rangeHeader, "bytes=") {
		return 0, -1, false
	}

	rangeSpec := strings.TrimPrefix(rangeHeader, "bytes=")
	parts := strings.Split(rangeSpec, "-")
	if len(parts) != 2 {
		return 0, -1, false
	}

	var err error
	start, err = strconv.ParseInt(parts[0], 10, 64)
	if err != nil || start < 0 {
		return 0, -1, false
	}

	if parts[1] == "" {
		// Range extends to end: "bytes=1024-"
		return start, -1, true
	}

	end, err = strconv.ParseInt(parts[1], 10, 64)
	if err != nil || end < start {
		return 0, -1, false
	}

	return start, end, true
}

// Parses duration from URL path component (e.g., "123.45" -> 123.45)
func parseDurationFromPath(durationStr string) (float64, error) {
	duration, err := strconv.ParseFloat(durationStr, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid duration format: %s", durationStr)
	}
	if duration <= 0 {
		return 0, fmt.Errorf("duration must be positive: %s", durationStr)
	}
	return duration, nil
}

// Parses segment number from segment filename (e.g., "segment_5.ts" -> 5)
func parseSegmentNumber(filename string) (int, error) {
	if !strings.HasPrefix(filename, "segment_") {
		return 0, fmt.Errorf("invalid segment filename: %s", filename)
	}

	parts := strings.Split(filename, "_")
	if len(parts) < 2 {
		return 0, fmt.Errorf("invalid segment filename: %s", filename)
	}

	segmentStr := strings.TrimSuffix(parts[1], ".ts")
	segmentNum, err := strconv.Atoi(segmentStr)
	if err != nil {
		return 0, fmt.Errorf("invalid segment number: %s", segmentStr)
	}

	return segmentNum, nil
}

// Logs HTTP request in Common Log Format: host - - [timestamp] "method path protocol" status size
func logCommonLogFormat(r *http.Request, statusCode int, size int64) {
	timestamp := time.Now().Format("02/Jan/2006:15:04:05 -0700")
	host := r.RemoteAddr
	if host == "" {
		host = "-"
	}
	log.Printf("%s - - [%s] \"%s %s %s\" %d %d",
		host,
		timestamp,
		r.Method,
		r.URL.Path,
		r.Proto,
		statusCode,
		size,
	)
}

// Returns a human-readable request type for logging
func getRequestType(path string) string {
	if strings.Contains(path, "/playlist.m3u8") {
		// Count slashes: /hls/{hash}/{duration}/playlist.m3u8 = 4 slashes (master)
		// /hls/{hash}/{quality}/{duration}/playlist.m3u8 = 5 slashes (variant)
		slashCount := strings.Count(path, "/")
		if slashCount == 5 {
			return "variant-playlist"
		}
		if slashCount == 4 {
			return "master-playlist"
		}
		return "playlist"
	}
	if strings.Contains(path, "/segment_") {
		return "segment"
	}
	return "unknown"
}
