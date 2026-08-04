package transcoded

import "fmt"

// Represents an error when fetching from upstream server fails
type UpstreamError struct {
	Hash string
	Err  error
}

func (e *UpstreamError) Error() string {
	return fmt.Sprintf("upstream fetch failed for hash %s: %v", e.Hash, e.Err)
}

func (e *UpstreamError) Unwrap() error {
	return e.Err
}

// Represents an error when ffmpeg transcoding fails
type TranscodingError struct {
	Hash string
	Err  error
}

func (e *TranscodingError) Error() string {
	return fmt.Sprintf("transcoding failed for hash %s: %v", e.Hash, e.Err)
}

func (e *TranscodingError) Unwrap() error {
	return e.Err
}

// Represents an error when hash format is invalid
type InvalidHashError struct {
	Hash string
}

func (e *InvalidHashError) Error() string {
	return fmt.Sprintf("invalid hash format: %s (must be 64 hex characters)", e.Hash)
}

// Represents an error when segment number is invalid
type InvalidSegmentError struct {
	Segment int
}

func (e *InvalidSegmentError) Error() string {
	return fmt.Sprintf("invalid segment number: %d", e.Segment)
}

