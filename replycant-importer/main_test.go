package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"image"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/bep/imagemeta"
	"github.com/google/uuid"
	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/lfsclient"
	"gopkg.in/yaml.v3"
)

// gitCmdLog records git argv lists so tests can assert push/rebase control flow.
type gitCmdLog struct {
	mu   sync.Mutex
	cmds [][]string
}

// record stores one git invocation for later assertions.
func (l *gitCmdLog) record(args []string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.cmds = append(l.cmds, append([]string(nil), args...))
}

// snapshot returns a copy of recorded git argv lists.
func (l *gitCmdLog) snapshot() [][]string {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([][]string, len(l.cmds))
	for i, c := range l.cmds {
		out[i] = append([]string(nil), c...)
	}
	return out
}

// containsSubcmd reports whether any recorded git command used the given subcommand.
func (l *gitCmdLog) containsSubcmd(name string) bool {
	for _, c := range l.snapshot() {
		if gitSubcommand(c) == name {
			return true
		}
	}
	return false
}

// rebaseInvocations returns rebase argv lists excluding abort cleanup calls.
func (l *gitCmdLog) rebaseInvocations() [][]string {
	var out [][]string
	for _, c := range l.snapshot() {
		if gitSubcommand(c) != "rebase" {
			continue
		}
		if sliceContains(c, "--abort") {
			continue
		}
		out = append(out, c)
	}
	return out
}

// sliceContains reports whether needle appears in values.
func sliceContains(values []string, needle string) bool {
	for _, v := range values {
		if v == needle {
			return true
		}
	}
	return false
}

// TestMain fails fast when required media tools are missing so CI does not
// report a false-green run with zero importer coverage.
func TestMain(m *testing.M) {
	for _, tool := range []string{"ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			fmt.Fprintf(os.Stderr, "%s is required for replycant-importer tests\n", tool)
			os.Exit(1)
		}
	}
	os.Exit(m.Run())
}

// TestImportPhotoManifestAndThumbnails verifies photo import creates expected artifacts.
func TestImportPhotoManifestAndThumbnails(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))

	imp, stderr, pushCalls, _ := newTestImporter(t, nil)
	err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	})
	if err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if strings.TrimSpace(stderr.String()) != "" {
		t.Fatalf("unexpected stderr: %s", stderr.String())
	}
	if got := atomic.LoadInt32(pushCalls); got != 0 {
		t.Fatalf("unexpected pushes: %d", got)
	}

	originals, thumbs := listManifestPaths(t, repo, "device-a")
	if len(originals) != 1 {
		t.Fatalf("expected 1 original manifest, got %d", len(originals))
	}
	if len(thumbs) != 1 {
		t.Fatalf("expected 1 thumbnail set manifest, got %d", len(thumbs))
	}

	var om OriginalManifest
	readYAML(t, originals[0], &om)
	if om.APIVersion != apiVersion || om.Kind != "Original" {
		t.Fatalf("unexpected original manifest header: %+v", om)
	}
	if om.Metadata.DeviceSpace != "device-a" {
		t.Fatalf("unexpected device space: %s", om.Metadata.DeviceSpace)
	}
	if om.Spec.MediaType != "photo" {
		t.Fatalf("expected photo mediaType, got %s", om.Spec.MediaType)
	}
	if om.Spec.SHA256 == "" || om.Spec.Filesize <= 0 || om.Spec.Width <= 0 || om.Spec.Height <= 0 {
		t.Fatalf("missing expected original fields: %+v", om.Spec)
	}

	var tm ThumbnailSetManifest
	readYAML(t, thumbs[0], &tm)
	if tm.APIVersion != apiVersion || tm.Kind != "ThumbnailSet" {
		t.Fatalf("unexpected thumb set header for %s", thumbs[0])
	}
	if tm.Metadata.DeviceSpace != "device-a" {
		t.Fatalf("unexpected thumb set device space: %s", tm.Metadata.DeviceSpace)
	}
	if tm.Spec.OriginalRef != "device-a/"+apiVersion+"/Original/"+om.Metadata.Name {
		t.Fatalf("unexpected originalRef: %s", tm.Spec.OriginalRef)
	}
	if len(tm.Spec.Thumbnails) != 3 {
		t.Fatalf("expected 3 thumbnail entries, got %d", len(tm.Spec.Thumbnails))
	}
	for _, entry := range tm.Spec.Thumbnails {
		if entry.SHA256 == "" || entry.Filesize <= 0 {
			t.Fatalf("missing thumb entry fields: %+v", entry)
		}
		if entry.Width <= 0 || entry.Height <= 0 {
			t.Fatalf("invalid thumb entry size: %+v", entry)
		}
		binPath := filepath.Join(repo, "binary", "device-a", apiVersion, "ThumbnailSet", shardName(entry.Name))
		if _, err := os.Stat(binPath); err != nil {
			t.Fatalf("missing thumbnail binary %s: %v", binPath, err)
		}
	}
}

// TestDedupAcrossDeviceSpaces verifies existing SHA in any device space is skipped.
func TestDedupAcrossDeviceSpaces(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	input := filepath.Join(srcDir, "a.jpg")
	writeTinyJPEG(t, input)

	imp, _, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("initial run failed: %v", err)
	}
	firstCount := commitCount(t, repo)

	originals, _ := listManifestPaths(t, repo, "device-a")
	var om OriginalManifest
	readYAML(t, originals[0], &om)

	seedOriginalManifest(t, repo, "device-b", "seeded-name", om.Spec.SHA256)
	firstCount = commitCount(t, repo)

	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-c",
	}); err != nil {
		t.Fatalf("second run failed: %v", err)
	}
	secondCount := commitCount(t, repo)
	if secondCount != firstCount {
		t.Fatalf("expected no new commits on dedup; before=%d after=%d", firstCount, secondCount)
	}
}

// TestPathSizeFastDedupSkipsHash verifies path+filesize duplicate detection skips hashing/probing.
func TestPathSizeFastDedupSkipsHash(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	input := filepath.Join(srcDir, "a.jpg")
	writeTinyJPEG(t, input)

	imp, _, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("initial run failed: %v", err)
	}
	firstCount := commitCount(t, repo)

	b, err := os.ReadFile(input)
	if err != nil {
		t.Fatal(err)
	}
	// Keep the same size but invalidate content. Fast path should skip before hashing/probing.
	if err := os.WriteFile(input, bytes.Repeat([]byte("x"), len(b)), 0o644); err != nil {
		t.Fatal(err)
	}

	imp2, stderr, _, _ := newTestImporter(t, nil)
	if err := imp2.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("second run failed: %v", err)
	}
	if got := commitCount(t, repo); got != firstCount {
		t.Fatalf("expected no new commit with same path+filesize; before=%d after=%d", firstCount, got)
	}
	if strings.Contains(stderr.String(), "error importing") {
		t.Fatalf("expected fast-path skip without processing errors, got stderr: %s", stderr.String())
	}
}

// TestImportCommitsAllFiles verifies all files are committed, regardless of batching.
func TestImportCommitsAllFiles(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "b.jpg"), "blue")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "c.jpg"), "green")

	before := commitCount(t, repo)
	imp, _, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	after := commitCount(t, repo)
	if after-before < 1 {
		t.Fatalf("expected at least 1 new commit, got %d", after-before)
	}
	originals, _ := listManifestPaths(t, repo, "device-a")
	if len(originals) != 3 {
		t.Fatalf("expected 3 original manifests, got %d", len(originals))
	}
}

// TestCommitIsolationSkipsUntracked verifies commit only includes generated import files.
func TestCommitIsolationSkipsUntracked(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))

	stalePath := filepath.Join(repo, "stale-untracked.txt")
	if err := os.WriteFile(stalePath, []byte("do not add"), 0o644); err != nil {
		t.Fatal(err)
	}

	imp, _, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}

	status := mustRun(t, repo, "git", "status", "--short")
	if !strings.Contains(status, "stale-untracked.txt") {
		t.Fatalf("expected stale file to remain untracked, status:\n%s", status)
	}
}

// TestUnsupportedFilesSkipped verifies non-media files are ignored.
func TestUnsupportedFilesSkipped(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(srcDir, "notes.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	before := commitCount(t, repo)
	imp, stderr, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	after := commitCount(t, repo)
	if after != before {
		t.Fatalf("expected no new commits, got before=%d after=%d", before, after)
	}
	if strings.TrimSpace(stderr.String()) != "" {
		t.Fatalf("unexpected stderr: %s", stderr.String())
	}
}

// TestVideoThumbnailImport verifies video path uses frame extraction and thumbnail writes.
func TestVideoThumbnailImport(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	video := filepath.Join(srcDir, "a.mp4")
	makeTinyVideo(t, video)

	imp, stderr, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}

	originals, thumbs := listManifestPaths(t, repo, "device-a")
	if len(originals) != 1 || len(thumbs) != 1 {
		t.Fatalf("expected 1 original + 1 thumbnail set, got %d + %d, stderr: %s", len(originals), len(thumbs), stderr.String())
	}
	var om OriginalManifest
	readYAML(t, originals[0], &om)
	if om.Spec.MediaType != "video" {
		t.Fatalf("expected video media type, got %s", om.Spec.MediaType)
	}
	if om.Spec.Duration == nil || *om.Spec.Duration <= 0 {
		t.Fatalf("expected positive video duration, got %+v", om.Spec.Duration)
	}
}

// TestVideoMetadataExtraction verifies creation_time is mapped into takenAt fields.
func TestVideoMetadataExtraction(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	video := filepath.Join(srcDir, "with-meta.mp4")
	makeTinyVideoWithCreationTime(t, video, "2024-06-15T10:30:00Z")

	imp, _, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}

	originals, _ := listManifestPaths(t, repo, "device-a")
	if len(originals) != 1 {
		t.Fatalf("expected 1 original, got %d", len(originals))
	}
	var om OriginalManifest
	readYAML(t, originals[0], &om)
	if om.Spec.TakenAt == "" {
		t.Fatalf("expected takenAt to be set from video metadata")
	}
	if om.Spec.GuessedTakenAt == "" {
		t.Fatalf("expected guessedTakenAt to be set")
	}
}

// TestImageMetadataPropagation verifies extracted image metadata is written to manifests.
func TestImageMetadataPropagation(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))
	tmpJPEG := filepath.Join(srcDir, "tmp.jpg")
	writeTinyJPEGColor(t, tmpJPEG, "blue")
	heicPath := filepath.Join(srcDir, "b.heic")
	b, err := os.ReadFile(tmpJPEG)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(heicPath, b, 0o644); err != nil {
		t.Fatal(err)
	}

	imp, _, _, _ := newTestImporter(t, nil)
	imp.extractPhotoMetadata = func(path string) (string, *OriginalLocation, int) {
		if strings.HasSuffix(path, ".jpg") {
			alt := 12.5
			return "2024-06-15T10:30:00Z", &OriginalLocation{
				Latitude:  59.3293,
				Longitude: 18.0686,
				Altitude:  &alt,
			}, 1
		}
		return "2023-01-02T03:04:05Z", nil, 1
	}

	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		Workers:     1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}

	originals, _ := listManifestPaths(t, repo, "device-a")
	if len(originals) != 2 {
		t.Fatalf("expected 2 originals, got %d", len(originals))
	}
	seenTakenAt := map[string]bool{}
	for _, p := range originals {
		var om OriginalManifest
		readYAML(t, p, &om)
		seenTakenAt[om.Spec.TakenAt] = true
		if om.Spec.GuessedTakenAt == "" {
			t.Fatalf("expected guessedTakenAt for %s", p)
		}
	}
	if !seenTakenAt["2024-06-15T10:30:00Z"] || !seenTakenAt["2023-01-02T03:04:05Z"] {
		t.Fatalf("expected propagated takenAt values, got %#v", seenTakenAt)
	}
}

// TestApplyOrientationBounds verifies orientation transforms keep or swap bounds as expected.
func TestApplyOrientationBounds(t *testing.T) {
	src := image.NewNRGBA(image.Rect(0, 0, 64, 32))
	for orientation := 1; orientation <= 8; orientation++ {
		got := applyOrientation(src, orientation).Bounds()
		gotW := got.Dx()
		gotH := got.Dy()
		wantW, wantH := 64, 32
		if orientation >= 5 {
			wantW, wantH = 32, 64
		}
		if gotW != wantW || gotH != wantH {
			t.Fatalf("orientation %d: expected %dx%d, got %dx%d", orientation, wantW, wantH, gotW, gotH)
		}
	}
}

// TestImportPhotoOrientedDimensions verifies original and thumbnail dimensions use oriented photo bounds.
func TestImportPhotoOrientedDimensions(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	input := filepath.Join(srcDir, "portrait.jpg")
	writeTinyJPEGColorSize(t, input, "red", 64, 32)

	imp, _, _, _ := newTestImporter(t, nil)
	imp.extractPhotoMetadata = func(path string) (string, *OriginalLocation, int) {
		return "", nil, 6
	}
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		Workers:     1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}

	originals, thumbs := listManifestPaths(t, repo, "device-a")
	if len(originals) != 1 || len(thumbs) != 1 {
		t.Fatalf("expected 1 original + 1 thumbnail set, got %d + %d", len(originals), len(thumbs))
	}

	var om OriginalManifest
	readYAML(t, originals[0], &om)
	if om.Spec.Width != 32 || om.Spec.Height != 64 {
		t.Fatalf("expected oriented original dimensions 32x64, got %dx%d", om.Spec.Width, om.Spec.Height)
	}

	var tm ThumbnailSetManifest
	readYAML(t, thumbs[0], &tm)
	var found1024 bool
	for _, entry := range tm.Spec.Thumbnails {
		if !strings.HasSuffix(entry.Name, "-thumb-1024") {
			continue
		}
		found1024 = true
		if entry.Width != 512 || entry.Height != 1024 {
			t.Fatalf("expected oriented 1024 thumbnail dimensions 512x1024, got %dx%d", entry.Width, entry.Height)
		}
	}
	if !found1024 {
		t.Fatal("expected 1024 thumbnail entry")
	}
}

// TestProbeMediaVideoRotationSwapsDimensions verifies video dimensions are display-oriented.
func TestProbeMediaVideoRotationSwapsDimensions(t *testing.T) {
	cases := []struct {
		name    string
		jsonOut string
		wantW   int
		wantH   int
	}{
		{
			name: "side_data rotation -90 swaps",
			jsonOut: `{
				"streams":[{"codec_type":"video","width":1920,"height":1080,"duration":"1.0","side_data_list":[{"rotation":-90}]}],
				"format":{"duration":"1.0","tags":{"creation_time":"2024-01-01T12:00:00Z"}}
			}`,
			wantW: 1080,
			wantH: 1920,
		},
		{
			name: "side_data rotation 180 keeps orientation",
			jsonOut: `{
				"streams":[{"codec_type":"video","width":1920,"height":1080,"duration":"1.0","side_data_list":[{"rotation":180}]}],
				"format":{"duration":"1.0","tags":{"creation_time":"2024-01-01T12:00:00Z"}}
			}`,
			wantW: 1920,
			wantH: 1080,
		},
		{
			name: "legacy tag rotate 90 swaps",
			jsonOut: `{
				"streams":[{"codec_type":"video","width":1920,"height":1080,"duration":"1.0","tags":{"rotate":"90"}}],
				"format":{"duration":"1.0","tags":{"creation_time":"2024-01-01T12:00:00Z"}}
			}`,
			wantW: 1080,
			wantH: 1920,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			imp := &importer{
				runCmd: func(_ string, name string, _ ...string) ([]byte, error) {
					if name != "ffprobe" {
						t.Fatalf("unexpected command: %s", name)
					}
					return []byte(tc.jsonOut), nil
				},
			}
			meta, err := imp.probeMedia("video.mp4", "video")
			if err != nil {
				t.Fatalf("probeMedia failed: %v", err)
			}
			if meta.width != tc.wantW || meta.height != tc.wantH {
				t.Fatalf("expected %dx%d, got %dx%d", tc.wantW, tc.wantH, meta.width, meta.height)
			}
		})
	}
}

// TestNormalizePhotoOrientation verifies HEIF avoids double-rotation while other formats keep EXIF orientation.
func TestNormalizePhotoOrientation(t *testing.T) {
	if got := normalizePhotoOrientation(imagemeta.HEIF, 6); got != 1 {
		t.Fatalf("expected HEIF orientation to normalize to 1, got %d", got)
	}
	if got := normalizePhotoOrientation(imagemeta.JPEG, 6); got != 6 {
		t.Fatalf("expected JPEG orientation to remain 6, got %d", got)
	}
}

// TestErrorContinue verifies one bad file does not prevent importing good files.
func TestErrorContinue(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "ok.jpg"))
	if err := os.WriteFile(filepath.Join(srcDir, "broken.jpg"), []byte("not-an-image"), 0o644); err != nil {
		t.Fatal(err)
	}

	imp, stderr, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}

	originals, _ := listManifestPaths(t, repo, "device-a")
	if len(originals) != 1 {
		t.Fatalf("expected one successful import, got %d", len(originals))
	}
	if !strings.Contains(stderr.String(), "error importing") {
		t.Fatalf("expected stderr to contain import error, got: %s", stderr.String())
	}
}

// TestGracefulCtrlC verifies cancellation limits the number of imported files.
func TestGracefulCtrlC(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "b.jpg"), "blue")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "c.jpg"), "green")

	var mediaCmdCalls int32
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	imp, _, _, _ := newTestImporter(t, func(name string, _ []string) {
		if name != "ffprobe" && name != "ffmpeg" {
			return
		}
		n := atomic.AddInt32(&mediaCmdCalls, 1)
		if n == 1 {
			go func() {
				time.Sleep(20 * time.Millisecond)
				cancel()
			}()
		}
		time.Sleep(120 * time.Millisecond)
	})

	if err := imp.run(ctx, CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		Workers:     1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if got := commitCount(t, repo); got < 1 || got > 2 {
		t.Fatalf("unexpected commit count after ctrl+c: %d", got)
	}
}

// TestPushEvery verifies periodic pushes happen in parallel after every N commits.
func TestPushEvery(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "b.jpg"), "blue")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "c.jpg"), "green")

	imp, _, pushCalls, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   2,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if got := atomic.LoadInt32(pushCalls); got < 1 {
		t.Fatalf("expected at least one push, got %d", got)
	}
}

// TestPushRebasesWhenRemoteMovedAhead verifies a rejected push fetches, rebases, and
// retries so concurrent remote commits are incorporated into linear history.
func TestPushRebasesWhenRemoteMovedAhead(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	foreignSHA := advanceRemoteWithForeignCommit(t, remoteURL(t, repo))

	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, _, _, cmds := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if !cmds.containsSubcmd("rebase") {
		t.Fatalf("expected rebase after rejected push, cmds=%v", cmds.snapshot())
	}
	if _, err := defaultRunCmd(repo, "git", "merge-base", "--is-ancestor", foreignSHA, "HEAD"); err != nil {
		t.Fatalf("expected foreign commit %s to be ancestor of HEAD after rebase: %v", foreignSHA, err)
	}
	merges := strings.TrimSpace(mustRun(t, repo, "git", "rev-list", "--merges", "HEAD"))
	if merges != "" {
		t.Fatalf("expected linear history after rebase, found merge commits: %s", merges)
	}
	local := strings.TrimSpace(mustRun(t, repo, "git", "rev-parse", "HEAD"))
	remote := strings.TrimSpace(mustRun(t, repo, "git", "ls-remote", "origin", "refs/heads/main"))
	remoteSHA := strings.Fields(remote)[0]
	if local != remoteSHA {
		t.Fatalf("expected local HEAD %s to match remote %s after successful retry push", local, remoteSHA)
	}
}

// TestPushRetriesWhenRemoteKeepsMoving verifies the bounded push/fetch/rebase loop
// recovers when the remote advances again between the first rejection and the retry.
func TestPushRetriesWhenRemoteKeepsMoving(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	remote := remoteURL(t, repo)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, _, _, cmds := newTestImporter(t, nil)
	var pushAttempts int32
	baseRun := imp.runCmd
	imp.runCmd = func(dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "push" {
			n := atomic.AddInt32(&pushAttempts, 1)
			if n <= 2 {
				_ = advanceRemoteWithForeignCommit(t, remote)
			}
		}
		return baseRun(dir, name, args...)
	}

	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if got := len(cmds.rebaseInvocations()); got < 2 {
		t.Fatalf("expected at least two rebases under a moving remote, got %d cmds=%v", got, cmds.snapshot())
	}
	local := strings.TrimSpace(mustRun(t, repo, "git", "rev-parse", "HEAD"))
	remoteTip := strings.TrimSpace(mustRun(t, repo, "git", "ls-remote", "origin", "refs/heads/main"))
	remoteSHA := strings.Fields(remoteTip)[0]
	if local != remoteSHA {
		t.Fatalf("expected local HEAD %s to match remote %s after retries", local, remoteSHA)
	}
}

// TestPushGivesUpAfterAttemptCap ensures pushWithRebase stops after the retry budget
// when the remote keeps advancing, leaving the repo without rebase state.
func TestPushGivesUpAfterAttemptCap(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	remote := remoteURL(t, repo)
	// Seed a local commit so push is non-empty and can be rejected repeatedly.
	if err := os.WriteFile(filepath.Join(repo, "seed.txt"), []byte("seed"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustRun(t, repo, "git", "add", "seed.txt")
	mustRun(t, repo, "git", "-c", "user.name=importer", "-c", "user.email=i@t", "commit", "-m", "seed")

	imp, _, _, cmds := newTestImporter(t, nil)
	baseRun := imp.runCmd
	imp.runCmd = func(dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "push" {
			_ = advanceRemoteWithForeignCommit(t, remote)
		}
		return baseRun(dir, name, args...)
	}

	err := imp.pushWithRebase(repo)
	if err == nil {
		t.Fatal("expected pushWithRebase to fail after exhausting retries")
	}
	pushCount := 0
	for _, c := range cmds.snapshot() {
		if gitSubcommand(c) == "push" {
			pushCount++
		}
	}
	if pushCount != pushRebaseMaxAttempts {
		t.Fatalf("expected %d push attempts, got %d cmds=%v", pushRebaseMaxAttempts, pushCount, cmds.snapshot())
	}
	if _, err := os.Stat(filepath.Join(repo, ".git", "rebase-merge")); !os.IsNotExist(err) {
		t.Fatalf("expected no rebase-merge state, stat err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(repo, ".git", "rebase-apply")); !os.IsNotExist(err) {
		t.Fatalf("expected no rebase-apply state, stat err=%v", err)
	}
	mustRun(t, repo, "git", "status", "--porcelain")
}

// logSink captures importer log output written from concurrent commit/push
// goroutines so tests can assert on progress reporting.
type logSink struct {
	mu  sync.Mutex
	buf strings.Builder
}

// printf matches the importer log signature.
func (s *logSink) printf(format string, args ...any) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.WriteString(fmt.Sprintf(format, args...))
}

// text returns everything logged so far.
func (s *logSink) text() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

// TestPushLogsLifecycle verifies every push cycle reports its start and completion,
// so a slow LFS upload is distinguishable from a hung importer.
func TestPushLogsLifecycle(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, _, _, _ := newTestImporter(t, nil)
	sink := &logSink{}
	imp.log = sink.printf

	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	out := sink.text()
	for _, want := range []string{"push: start", "push: done", "commit: 1 file"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected log to contain %q, log=%q", want, out)
		}
	}
}

// TestPushLogsRejectionAndRebase verifies a lost push race is reported with the
// attempt number and the rebase that recovers it, instead of failing silently.
func TestPushLogsRejectionAndRebase(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	_ = advanceRemoteWithForeignCommit(t, remoteURL(t, repo))
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, _, _, _ := newTestImporter(t, nil)
	sink := &logSink{}
	imp.log = sink.printf

	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	out := sink.text()
	for _, want := range []string{
		"push: attempt 1/5 rejected",
		"push: rebased onto origin/main",
		"push: done attempts=2",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected log to contain %q, log=%q", want, out)
		}
	}
}

// TestVerboseStreamsGitPushOutput verifies --verbose surfaces pre-push hook output
// while the push runs, since that is where LFS upload progress is reported.
func TestVerboseStreamsGitPushOutput(t *testing.T) {
	const marker = "PREPUSH-HOOK-MARKER"
	runImport := func(verbose bool) string {
		repo := initTempRepoWithRemote(t)
		hook := "#!/bin/sh\ncat > /dev/null\necho " + marker + " >&2\nexit 0\n"
		if err := os.WriteFile(filepath.Join(repo, ".git", "hooks", "pre-push"), []byte(hook), 0o755); err != nil {
			t.Fatal(err)
		}
		srcDir := t.TempDir()
		writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

		imp, stderr, _, _ := newTestImporter(t, nil)
		if err := imp.run(context.Background(), CLI{
			Repo:        repo,
			Source:      srcDir,
			DeviceSpace: "device-a",
			PushEvery:   1,
			Verbose:     verbose,
		}); err != nil {
			t.Fatalf("run failed: %v", err)
		}
		return stderr.String()
	}
	if got := runImport(true); !strings.Contains(got, marker) {
		t.Fatalf("expected hook output streamed with --verbose, stderr=%q", got)
	}
	if got := runImport(false); strings.Contains(got, marker) {
		t.Fatalf("expected hook output suppressed without --verbose, stderr=%q", got)
	}
}

// TestVerboseDoesNotStreamMediaToolOutput pins that verbose mode only mirrors remote
// git operations; ffmpeg/ffprobe run per file and would flood the log.
func TestVerboseDoesNotStreamMediaToolOutput(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, stderr, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
		Verbose:     true,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	// ffprobe/ffmpeg always announce themselves on stderr with a version banner.
	if got := stderr.String(); strings.Contains(got, "ffprobe version") || strings.Contains(got, "ffmpeg version") {
		t.Fatalf("expected media tool stderr to stay suppressed, stderr=%q", got)
	}
}

// TestPushSkipsRebaseWhenPushSucceeds ensures the happy path never pays for fetch/rebase.
func TestPushSkipsRebaseWhenPushSucceeds(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, _, _, cmds := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if cmds.containsSubcmd("fetch") {
		t.Fatalf("unexpected fetch when push succeeded: %v", cmds.snapshot())
	}
	if cmds.containsSubcmd("rebase") {
		t.Fatalf("unexpected rebase when push succeeded: %v", cmds.snapshot())
	}
}

// TestPushRebaseAbortsAndLeavesRepoUsable verifies a failed rebase is aborted so later
// commits can continue, even when the final flush also fails.
func TestPushRebaseAbortsAndLeavesRepoUsable(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	_ = advanceRemoteWithForeignCommit(t, remoteURL(t, repo))
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, _, _, cmds := newTestImporter(t, nil)
	// Fail rebase (non-abort) without starting a real rebase so abort cleanup is exercised.
	baseRun := imp.runCmd
	imp.runCmd = func(dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "rebase" && !sliceContains(args, "--abort") {
			cmds.record(args)
			return nil, fmt.Errorf("injected rebase failure")
		}
		return baseRun(dir, name, args...)
	}

	_ = imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
	})
	if !cmds.containsSubcmd("rebase") {
		t.Fatalf("expected rebase attempt, cmds=%v", cmds.snapshot())
	}
	aborted := false
	for _, c := range cmds.snapshot() {
		if gitSubcommand(c) == "rebase" && sliceContains(c, "--abort") {
			aborted = true
			break
		}
	}
	if !aborted {
		t.Fatalf("expected rebase --abort after failure, cmds=%v", cmds.snapshot())
	}
	if _, err := os.Stat(filepath.Join(repo, ".git", "rebase-merge")); !os.IsNotExist(err) {
		t.Fatalf("expected no rebase-merge state, stat err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(repo, ".git", "rebase-apply")); !os.IsNotExist(err) {
		t.Fatalf("expected no rebase-apply state, stat err=%v", err)
	}
	// Repo must remain usable for subsequent git operations.
	mustRun(t, repo, "git", "status", "--porcelain")
}

// TestFinalPushFlushesRemainingCommits ensures leftovers below --push-every are pushed
// at end of run so an import does not silently leave commits local-only.
func TestFinalPushFlushesRemainingCommits(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "b.jpg"), "blue")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "c.jpg"), "green")

	imp, _, _, _ := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   5,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	local := strings.TrimSpace(mustRun(t, repo, "git", "rev-parse", "HEAD"))
	remote := strings.TrimSpace(mustRun(t, repo, "git", "ls-remote", "origin", "refs/heads/main"))
	remoteSHA := strings.Fields(remote)[0]
	if local != remoteSHA {
		t.Fatalf("expected final flush to push remaining commits: local=%s remote=%s", local, remoteSHA)
	}
}

// TestRebaseUsesMergeBackendAndNoAutostash pins the rebase argv that avoids smudging
// the entire unpushed binary backlog through the worktree.
func TestRebaseUsesMergeBackendAndNoAutostash(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	_ = advanceRemoteWithForeignCommit(t, remoteURL(t, repo))
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, _, _, cmds := newTestImporter(t, nil)
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}
	rebases := cmds.rebaseInvocations()
	if len(rebases) == 0 {
		t.Fatalf("expected at least one rebase, cmds=%v", cmds.snapshot())
	}
	for _, args := range rebases {
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "rebase.backend=merge") {
			t.Fatalf("expected rebase.backend=merge in %v", args)
		}
		if !sliceContains(args, "--no-autostash") {
			t.Fatalf("expected --no-autostash in %v", args)
		}
	}
}

// newTestImporter creates an importer with command spying while keeping real execution.
func newTestImporter(t *testing.T, hook func(name string, args []string)) (*importer, *bytes.Buffer, *int32, *gitCmdLog) {
	t.Helper()
	var stderr bytes.Buffer
	var pushCalls int32
	cmds := &gitCmdLog{}
	// Commands run through the importer's own leaf so verbose stderr mirroring
	// still applies to spied invocations.
	var imp *importer
	run := func(dir string, name string, args ...string) ([]byte, error) {
		if hook != nil {
			hook(name, args)
		}
		if name == "git" {
			cmds.record(args)
			if gitSubcommand(args) == "push" {
				atomic.AddInt32(&pushCalls, 1)
			}
		}
		return imp.execCmd(dir, name, args...)
	}
	imp = &importer{
		stderr:               &stderr,
		log:                  func(string, ...any) (int, error) { return 0, nil },
		runCmd:               run,
		newUUID:              func() string { return strings.ToLower(uuid.NewString()) },
		now:                  time.Now,
		extractPhotoMetadata: extractImageMetadata,
		// Fake uploader accepts every object so unit tests cover import/commit
		// flow without standing up a live LFS endpoint.
		uploadObjects: func(ctx context.Context, objects []lfsclient.Object, open lfsclient.OpenFunc) error {
			for _, object := range objects {
				reader, err := open(object)
				if err != nil {
					return err
				}
				_, err = io.Copy(io.Discard, reader)
				_ = reader.Close()
				if err != nil {
					return err
				}
			}
			return nil
		},
	}
	return imp, &stderr, &pushCalls, cmds
}

// remoteURL returns the configured origin URL for push/rebase integration tests.
func remoteURL(t *testing.T, repo string) string {
	t.Helper()
	return strings.TrimSpace(mustRun(t, repo, "git", "remote", "get-url", "origin"))
}

// advanceRemoteWithForeignCommit pushes an unrelated commit from a second clone so the
// importer's next push is rejected and must rebase. Content is unique per call so
// repeated advances against the same remote each produce a new commit.
func advanceRemoteWithForeignCommit(t *testing.T, remote string) string {
	t.Helper()
	other := t.TempDir()
	// Bare remotes created by git init still advertise HEAD=master; force main checkout.
	mustRun(t, "", "git", "clone", "-b", "main", remote, other)
	payload := []byte("foreign-" + uuid.NewString())
	if err := os.WriteFile(filepath.Join(other, "foreign.txt"), payload, 0o644); err != nil {
		t.Fatal(err)
	}
	mustRun(t, other, "git", "add", "foreign.txt")
	mustRun(t, other, "git", "-c", "user.name=foreign", "-c", "user.email=foreign@t", "commit", "-m", "foreign")
	sha := strings.TrimSpace(mustRun(t, other, "git", "rev-parse", "HEAD"))
	mustRun(t, other, "git", "push", "origin", "HEAD:main")
	return sha
}

// initTempRepo creates a --no-lfs-style replycant worktree with encryption and mTLS config.
func initTempRepo(t *testing.T) string {
	t.Helper()
	repo := t.TempDir()
	mustRun(t, repo, "git", "init")
	mustRun(t, repo, "git", "checkout", "-b", "main")
	local, _, err := gitcrypt.EnsureLocalIdentity(repo, "importer-test-device")
	if err != nil {
		t.Fatalf("ensure identity: %v", err)
	}
	recipientPub, err := gitcrypt.DecodeAgePublicKey(local.Identity.AgePublicKey)
	if err != nil {
		t.Fatalf("decode age pubkey: %v", err)
	}
	kek := make([]byte, 32)
	if _, err := rand.Read(kek); err != nil {
		t.Fatalf("generate kek: %v", err)
	}
	envelope, err := gitcrypt.WrapKEKForAge(kek, recipientPub)
	if err != nil {
		t.Fatalf("wrap kek: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(repo, "encryption", "epochs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "encryption", "current"), []byte("1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "encryption", "epochs", "1.age"), envelope, 0o644); err != nil {
		t.Fatal(err)
	}
	caPath := filepath.Join(local.ConfigDirectory, "ca.pem")
	certPEM, err := os.ReadFile(local.ClientCertPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(caPath, certPEM, 0o644); err != nil {
		t.Fatal(err)
	}
	mustRun(t, repo, "git", "config", "--local", "http.sslCAInfo", caPath)
	mustRun(t, repo, "git", "config", "--local", "http.sslCert", local.ClientCertPath)
	mustRun(t, repo, "git", "config", "--local", "http.sslKey", local.ClientKeyPath)
	mustRun(t, repo, "git", "remote", "add", "origin", "https://example.com/repo.git")
	if err := os.WriteFile(filepath.Join(repo, ".gitkeep"), []byte("init"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustRun(t, repo, "git", "add", ".")
	mustRun(t, repo, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init")
	return repo
}

// initTempRepoWithRemote creates repo + bare remote for push tests.
func initTempRepoWithRemote(t *testing.T) string {
	t.Helper()
	repo := initTempRepo(t)
	remote := t.TempDir()
	mustRun(t, remote, "git", "init", "--bare")
	mustRun(t, repo, "git", "remote", "set-url", "origin", remote)
	mustRun(t, repo, "git", "push", "-u", "origin", "main")
	return repo
}

// commitCount returns the number of commits in current branch.
func commitCount(t *testing.T, repo string) int {
	t.Helper()
	out := mustRun(t, repo, "git", "rev-list", "--count", "HEAD")
	n, err := strconv.Atoi(strings.TrimSpace(out))
	if err != nil {
		t.Fatalf("atoi commit count: %v", err)
	}
	return n
}

// listManifestPaths returns original and thumbnail manifest paths for a device.
func listManifestPaths(t *testing.T, repo, deviceSpace string) ([]string, []string) {
	t.Helper()
	root := filepath.Join(repo, "manifests", deviceSpace, apiVersion)
	var originals []string
	var thumbs []string
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || filepath.Ext(path) != ".yaml" {
			return nil
		}
		n := filepath.ToSlash(path)
		if strings.Contains(n, "/Original/") {
			originals = append(originals, path)
		}
		if strings.Contains(n, "/ThumbnailSet/") {
			thumbs = append(thumbs, path)
		}
		return nil
	})
	sort.Strings(originals)
	sort.Strings(thumbs)
	return originals, thumbs
}

// seedOriginalManifest creates one extra Original manifest in another device space.
func seedOriginalManifest(t *testing.T, repo, deviceSpace, name, sha string) {
	t.Helper()
	m := OriginalManifest{
		APIVersion: apiVersion,
		Kind:       "Original",
		Metadata:   ManifestMetadata{Name: name, DeviceSpace: deviceSpace},
		Spec: OriginalSpec{
			ID:         name,
			SHA256:     sha,
			Path:       "/tmp/x.jpg",
			Filesize:   1,
			MediaType:  "photo",
			Width:      1,
			Height:     1,
			IsFavorite: false,
			IsHidden:   false,
			CreatedAt:  time.Now().UTC().Format(time.RFC3339),
		},
		Status: map[string]any{},
	}
	path := filepath.Join(repo, "manifests", deviceSpace, apiVersion, "Original", shardName(name)+".yaml")
	if err := writeYAMLFile(path, m); err != nil {
		t.Fatal(err)
	}
	mustRun(t, repo, "git", "add", path)
	mustRun(t, repo, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "seed")
}

// readYAML loads a YAML file into destination for assertions.
func readYAML(t *testing.T, path string, dst any) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := yaml.Unmarshal(b, dst); err != nil {
		t.Fatal(err)
	}
}

// writeTinyJPEG writes a valid tiny JPEG fixture for photo import tests.
func writeTinyJPEG(t *testing.T, path string) {
	t.Helper()
	writeTinyJPEGColor(t, path, "red")
}

// writeTinyJPEGColor writes a valid tiny JPEG fixture with deterministic color.
func writeTinyJPEGColor(t *testing.T, path string, color string) {
	t.Helper()
	writeTinyJPEGColorSize(t, path, color, 64, 64)
}

// writeTinyJPEGColorSize writes a valid tiny JPEG fixture with deterministic color and size.
func writeTinyJPEGColorSize(t *testing.T, path string, color string, width int, height int) {
	t.Helper()
	_, err := defaultRunCmd("", "ffmpeg",
		"-y",
		"-loglevel", "error",
		"-f", "lavfi",
		"-i", fmt.Sprintf("color=c=%s:size=%dx%d:d=1", color, width, height),
		"-frames:v", "1",
		"-q:v", "2",
		path,
	)
	if err != nil {
		t.Fatalf("create jpeg fixture failed: %v", err)
	}
}

// makeTinyVideo creates a short synthetic mp4 fixture for video tests.
func makeTinyVideo(t *testing.T, path string) {
	t.Helper()
	_, err := defaultRunCmd("", "ffmpeg",
		"-y",
		"-loglevel", "error",
		"-f", "lavfi",
		"-i", "testsrc=size=64x64:rate=1:duration=1",
		"-pix_fmt", "yuv420p",
		path,
	)
	if err != nil {
		t.Fatalf("create video fixture failed: %v", err)
	}
}

// makeTinyVideoWithCreationTime creates an mp4 fixture with embedded creation_time.
func makeTinyVideoWithCreationTime(t *testing.T, path string, creationTime string) {
	t.Helper()
	_, err := defaultRunCmd("", "ffmpeg",
		"-y",
		"-loglevel", "error",
		"-f", "lavfi",
		"-i", "testsrc=size=64x64:rate=1:duration=1",
		"-pix_fmt", "yuv420p",
		"-metadata", "creation_time="+creationTime,
		path,
	)
	if err != nil {
		t.Fatalf("create video fixture with metadata failed: %v", err)
	}
}

// mustRun executes command and fails test immediately with stderr context on errors.
func mustRun(t *testing.T, dir, name string, args ...string) string {
	t.Helper()
	out, err := defaultRunCmd(dir, name, args...)
	if err != nil {
		t.Fatalf("%s %v failed: %v", name, args, err)
	}
	return string(out)
}
