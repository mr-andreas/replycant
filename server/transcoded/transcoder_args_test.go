package transcoded

import (
	"strings"
	"testing"
)

// getArgValue keeps ffmpeg argument assertions concise across profiles.
func getArgValue(args []string, key string) (string, bool) {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == key {
			return args[i+1], true
		}
	}
	return "", false
}

// TestArgSetsDoNotForceTranspose protects autorotate behavior by banning
// hardcoded transpose filters that can double-rotate sources.
func TestArgSetsDoNotForceTranspose(t *testing.T) {
	quality := QualityVariant{
		Name:         "test",
		Width:        1280,
		Height:       720,
		VideoBitrate: 2_500_000,
		AudioBitrate: 128_000,
	}

	for name, buildArgs := range argSets {
		args := buildArgs("https://example.invalid/video.mp4", 0, 10, quality, "")
		vf, ok := getArgValue(args, "-vf")
		if !ok {
			t.Fatalf("arg set %q missing -vf filter", name)
		}
		if strings.Contains(vf, "transpose=") {
			t.Fatalf("arg set %q hardcodes transpose filter: %q", name, vf)
		}
	}
}
