package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"image"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/bep/imagemeta"
	"github.com/google/uuid"
	"github.com/mr-andreas/replycant/internal/gittest"
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
				runCmd: func(_ context.Context, _ string, name string, _ ...string) ([]byte, error) {
					if name != "ffprobe" {
						t.Fatalf("unexpected command: %s", name)
					}
					return []byte(tc.jsonOut), nil
				},
			}
			meta, err := imp.probeMedia(context.Background(), "video.mp4", "video")
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

// TestSourceQueueFIFO verifies push/pop preserve discovery order.
func TestSourceQueueFIFO(t *testing.T) {
	q := newSourceQueue()
	q.push(sourceFile{index: 0, path: "a.jpg"})
	q.push(sourceFile{index: 1, path: "b.jpg"})
	q.close()

	first, ok := q.pop()
	if !ok || first.path != "a.jpg" {
		t.Fatalf("expected a.jpg, got %+v ok=%v", first, ok)
	}
	second, ok := q.pop()
	if !ok || second.path != "b.jpg" {
		t.Fatalf("expected b.jpg, got %+v ok=%v", second, ok)
	}
	if _, ok := q.pop(); ok {
		t.Fatal("expected empty closed queue to return ok=false")
	}
}

// TestSourceQueuePopBlocksUntilPush verifies pop waits for work instead of
// spinning or returning early while the scanner is still running.
func TestSourceQueuePopBlocksUntilPush(t *testing.T) {
	q := newSourceQueue()
	done := make(chan sourceFile, 1)
	go func() {
		job, ok := q.pop()
		if !ok {
			t.Error("expected pop to receive a job")
			return
		}
		done <- job
	}()

	select {
	case <-done:
		t.Fatal("pop returned before push")
	case <-time.After(50 * time.Millisecond):
	}
	q.push(sourceFile{index: 0, path: "a.jpg"})
	select {
	case job := <-done:
		if job.path != "a.jpg" {
			t.Fatalf("unexpected job: %+v", job)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for blocked pop")
	}
}

// TestSourceQueueCloseWakesBlockedPop verifies close unblocks workers waiting
// for work so shutdown does not hang after the scanner finishes.
func TestSourceQueueCloseWakesBlockedPop(t *testing.T) {
	q := newSourceQueue()
	done := make(chan bool, 1)
	go func() {
		_, ok := q.pop()
		done <- ok
	}()
	time.Sleep(20 * time.Millisecond)
	q.close()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("expected closed empty queue to return ok=false")
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for close to wake pop")
	}
}

// TestSourceQueueCloseDrainsQueuedItems verifies close does not drop items
// already discovered before the scanner finished.
func TestSourceQueueCloseDrainsQueuedItems(t *testing.T) {
	q := newSourceQueue()
	q.push(sourceFile{index: 0, path: "a.jpg"})
	q.close()
	job, ok := q.pop()
	if !ok || job.path != "a.jpg" {
		t.Fatalf("expected queued item after close, got %+v ok=%v", job, ok)
	}
	if _, ok := q.pop(); ok {
		t.Fatal("expected drained closed queue to return ok=false")
	}
}

// TestStreamSourceFilesNoConsumerCompletes verifies the scan finishes even when
// nothing drains the queue, so large libraries are not stuck in (calculating).
func TestStreamSourceFilesNoConsumerCompletes(t *testing.T) {
	srcDir := t.TempDir()
	const n = 2000
	for i := 0; i < n; i++ {
		// Empty files are enough: the walker only checks extensions.
		if err := os.WriteFile(filepath.Join(srcDir, fmt.Sprintf("%04d.jpg", i)), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	q := newSourceQueue()
	progress := &progressTotal{}
	done := make(chan error, 1)
	go func() {
		done <- streamSourceFiles(context.Background(), srcDir, q, progress)
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("streamSourceFiles failed: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("scan blocked behind consumers; expected unbounded queue to finish")
	}
	if !progress.done.Load() {
		t.Fatal("expected progress to be marked done")
	}
	if got := progress.found.Load(); got != n {
		t.Fatalf("expected found=%d, got %d", n, got)
	}
	if got := progress.label(); got != strconv.Itoa(n) {
		t.Fatalf("expected concrete total %q, got %q", strconv.Itoa(n), got)
	}
}

// TestStreamSourceFilesProgressLabel verifies listing reports a running found
// count until the walk finishes, then exposes the concrete total.
func TestStreamSourceFilesProgressLabel(t *testing.T) {
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))
	writeTinyJPEG(t, filepath.Join(srcDir, "b.jpg"))
	writeTinyJPEG(t, filepath.Join(srcDir, "c.jpg"))

	q := newSourceQueue()
	progress := &progressTotal{}
	errCh := make(chan error, 1)
	go func() {
		errCh <- streamSourceFiles(context.Background(), srcDir, q, progress)
	}()

	// Wait until at least one file is discovered without draining everything.
	deadline := time.Now().Add(time.Second)
	for progress.found.Load() < 1 {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for first discovery")
		}
		time.Sleep(time.Millisecond)
	}
	if got := progress.label(); got != "(calculating, 1 found)" &&
		got != "(calculating, 2 found)" &&
		got != "(calculating, 3 found)" {
		// Scan may finish before we sample; either running or done is fine
		// as long as the format is correct when still calculating.
		if !progress.done.Load() {
			t.Fatalf("unexpected progress label while scanning: %q", got)
		}
	}

	if err := <-errCh; err != nil {
		t.Fatalf("streamSourceFiles failed: %v", err)
	}
	if got := progress.label(); got != "3" {
		t.Fatalf("expected total 3 after walk, got %q", got)
	}

	var got []sourceFile
	for {
		job, ok := q.pop()
		if !ok {
			break
		}
		got = append(got, job)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 files, got %d", len(got))
	}
	if got[0].index != 0 {
		t.Fatalf("expected first index 0, got %d", got[0].index)
	}
}

// TestProgressTotalLabelRunningCount verifies the denominator shows how many
// files have been discovered while the scan is still running.
func TestProgressTotalLabelRunningCount(t *testing.T) {
	p := &progressTotal{}
	p.found.Store(1234)
	if got := p.label(); got != "(calculating, 1234 found)" {
		t.Fatalf("expected running count label, got %q", got)
	}
	p.finish()
	if got := p.label(); got != "1234" {
		t.Fatalf("expected concrete total, got %q", got)
	}
}

// TestStreamSourceFilesSkipsUnsupported verifies non-media files are ignored and
// media indices stay contiguous.
func TestStreamSourceFilesSkipsUnsupported(t *testing.T) {
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))
	if err := os.WriteFile(filepath.Join(srcDir, "notes.txt"), []byte("skip"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTinyJPEG(t, filepath.Join(srcDir, "b.jpg"))

	q := newSourceQueue()
	progress := &progressTotal{}
	if err := streamSourceFiles(context.Background(), srcDir, q, progress); err != nil {
		t.Fatalf("streamSourceFiles failed: %v", err)
	}
	var got []sourceFile
	for {
		job, ok := q.pop()
		if !ok {
			break
		}
		got = append(got, job)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 media files, got %d", len(got))
	}
	for i, job := range got {
		if job.index != i {
			t.Fatalf("expected contiguous index %d, got %d", i, job.index)
		}
		if mediaTypeFromPath(job.path) == "" {
			t.Fatalf("unexpected non-media path: %s", job.path)
		}
	}
	if got := progress.label(); got != "2" {
		t.Fatalf("expected total 2, got %q", got)
	}
}

// TestStreamSourceFilesCancel verifies a pre-cancelled context stops listing
// before any files are queued and still closes the queue for workers.
func TestStreamSourceFilesCancel(t *testing.T) {
	srcDir := t.TempDir()
	for i := 0; i < 20; i++ {
		if err := os.WriteFile(filepath.Join(srcDir, fmt.Sprintf("%02d.jpg", i)), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	q := newSourceQueue()
	progress := &progressTotal{}
	if err := streamSourceFiles(ctx, srcDir, q, progress); err != nil {
		t.Fatalf("streamSourceFiles failed after cancel: %v", err)
	}
	var delivered int
	for {
		_, ok := q.pop()
		if !ok {
			break
		}
		delivered++
	}
	if delivered != 0 {
		t.Fatalf("expected no files after pre-cancel, got %d", delivered)
	}
	if !progress.done.Load() {
		t.Fatal("expected progress to be marked done after cancel")
	}
}

// TestImportProgressUsesConcreteTotal verifies import progress lines switch from
// (calculating) during listing to a concrete denominator once scanning finishes.
func TestImportProgressUsesConcreteTotal(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))

	var logBuf bytes.Buffer
	var logMu sync.Mutex
	imp, _, _, _ := newTestImporter(t, nil)
	imp.log = func(format string, args ...any) (int, error) {
		logMu.Lock()
		defer logMu.Unlock()
		return fmt.Fprintf(&logBuf, format, args...)
	}

	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		Workers:     1,
	}); err != nil {
		t.Fatalf("run failed: %v", err)
	}

	logMu.Lock()
	logs := logBuf.String()
	logMu.Unlock()
	if !strings.Contains(logs, "[1/1] a.jpg imported") {
		t.Fatalf("expected concrete progress total in logs, got:\n%s", logs)
	}
	if strings.Contains(logs, "[1/(calculating)] a.jpg imported") {
		t.Fatalf("imported line should not keep (calculating) after walk finishes:\n%s", logs)
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

// TestRunCmdTeeKillsChildOnCancel verifies cancelled contexts kill child
// processes so Ctrl+C does not leave ffmpeg/git blocked in Wait.
func TestRunCmdTeeKillsChildOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	_, err := runCmdTee(nil, ctx, "", "sleep", "30")
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("runCmdTee did not return promptly after cancel: %s", elapsed)
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}

// TestCancelAbortsInFlightLFSUpload verifies cancelling workCtx stops a blocked
// LFS upload, leaves no commit, and rolls back partial manifests/pointers.
func TestCancelAbortsInFlightLFSUpload(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))

	workCtx, cancelWork := context.WithCancel(context.Background())
	defer cancelWork()
	uploadStarted := make(chan struct{})
	imp, _, _, _ := newTestImporter(t, nil)
	imp.uploadObjects = func(ctx context.Context, objects []lfsclient.Object, open lfsclient.OpenFunc) error {
		close(uploadStarted)
		<-ctx.Done()
		return ctx.Err()
	}

	done := make(chan error, 1)
	go func() {
		done <- imp.runStaged(workCtx, context.Background(), CLI{
			Repo:        repo,
			Source:      srcDir,
			DeviceSpace: "device-a",
			Workers:     1,
		})
	}()

	select {
	case <-uploadStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for LFS upload to start")
	}
	cancelWork()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runStaged failed: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("run did not return promptly after cancelling in-flight LFS upload")
	}

	if got := commitCount(t, repo); got != 1 {
		// init commit only
		t.Fatalf("expected only the initial repo commit, got %d", got)
	}
	originals, thumbs := listManifestPaths(t, repo, "device-a")
	if len(originals) != 0 || len(thumbs) != 0 {
		t.Fatalf("expected cancelled upload to remove manifests, got originals=%v thumbs=%v", originals, thumbs)
	}
	if leftover := countBinaryPointers(t, repo); leftover != 0 {
		t.Fatalf("expected no leftover pointer files, got %d", leftover)
	}
}

// TestCancelDoesNotReportContextCanceledAsImportError keeps cancellation from
// looking like a per-file failure in stderr.
func TestCancelDoesNotReportContextCanceledAsImportError(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))

	workCtx, cancelWork := context.WithCancel(context.Background())
	defer cancelWork()
	uploadStarted := make(chan struct{})
	imp, stderr, _, _ := newTestImporter(t, nil)
	imp.uploadObjects = func(ctx context.Context, objects []lfsclient.Object, open lfsclient.OpenFunc) error {
		close(uploadStarted)
		<-ctx.Done()
		return ctx.Err()
	}

	done := make(chan error, 1)
	go func() {
		done <- imp.runStaged(workCtx, context.Background(), CLI{
			Repo:        repo,
			Source:      srcDir,
			DeviceSpace: "device-a",
			Workers:     1,
		})
	}()
	select {
	case <-uploadStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for LFS upload to start")
	}
	cancelWork()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runStaged failed: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("run did not return promptly after cancel")
	}
	if strings.Contains(stderr.String(), "error importing") {
		t.Fatalf("cancellation should not log import errors, got: %s", stderr.String())
	}
}

// TestCancelStillFlushesPendingCommits verifies the first interrupt still pushes
// already-committed work when periodic push is enabled.
func TestCancelStillFlushesPendingCommits(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "b.jpg"), "blue")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "c.jpg"), "green")

	workCtx, cancelWork := context.WithCancel(context.Background())
	defer cancelWork()
	var mediaCmdCalls int32
	imp, _, pushCalls, _ := newTestImporter(t, func(name string, _ []string) {
		if name != "ffprobe" && name != "ffmpeg" {
			return
		}
		n := atomic.AddInt32(&mediaCmdCalls, 1)
		if n == 1 {
			go func() {
				time.Sleep(20 * time.Millisecond)
				cancelWork()
			}()
		}
		time.Sleep(80 * time.Millisecond)
	})

	if err := imp.runStaged(workCtx, context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
		Workers:     1,
	}); err != nil {
		t.Fatalf("runStaged failed: %v", err)
	}
	if got := atomic.LoadInt32(pushCalls); got < 1 {
		t.Fatalf("expected at least one push after cancel flush, got %d", got)
	}
	local := strings.TrimSpace(mustRun(t, repo, "git", "rev-parse", "HEAD"))
	remote := strings.TrimSpace(mustRun(t, repo, "git", "ls-remote", "origin", "refs/heads/main"))
	remoteSHA := strings.Fields(remote)[0]
	if local != remoteSHA {
		t.Fatalf("expected cancel flush to push commits: local=%s remote=%s", local, remoteSHA)
	}
}

// TestSecondInterruptAbortsFlushPush verifies a second cancel stops the final
// push and reports that commits remain local.
func TestSecondInterruptAbortsFlushPush(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	srcDir := t.TempDir()
	writeTinyJPEG(t, filepath.Join(srcDir, "a.jpg"))

	workCtx, cancelWork := context.WithCancel(context.Background())
	defer cancelWork()
	flushCtx, cancelFlush := context.WithCancel(context.Background())
	defer cancelFlush()

	imp, stderr, _, _ := newTestImporter(t, nil)
	baseRun := imp.runCmd
	pushStarted := make(chan struct{})
	imp.runCmd = func(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "push" {
			select {
			case <-pushStarted:
			default:
				close(pushStarted)
			}
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return baseRun(ctx, dir, name, args...)
	}

	done := make(chan error, 1)
	go func() {
		done <- imp.runStaged(workCtx, flushCtx, CLI{
			Repo:        repo,
			Source:      srcDir,
			DeviceSpace: "device-a",
			PushEvery:   5,
			Workers:     1,
		})
	}()

	select {
	case <-pushStarted:
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for final flush push")
	}
	cancelWork()
	cancelFlush()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runStaged failed: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("run did not return promptly after second interrupt")
	}
	if !strings.Contains(stderr.String(), "remain local") {
		t.Fatalf("expected local-commit hint after aborted flush, got: %s", stderr.String())
	}
}

// TestCancelWakesWorkersBlockedOnEmptyQueue mirrors run's AfterFunc(workCtx,
// queue.close) so cancellation does not leave workers parked in pop().
func TestCancelWakesWorkersBlockedOnEmptyQueue(t *testing.T) {
	q := newSourceQueue()
	ctx, cancel := context.WithCancel(context.Background())
	stop := context.AfterFunc(ctx, q.close)
	defer stop()

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = q.pop()
		}()
	}
	time.Sleep(30 * time.Millisecond)
	cancel()

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("workers stayed blocked after cancel closed the queue")
	}
}

// countBinaryPointers counts pointer files left under binary/ after a cancelled import.
func countBinaryPointers(t *testing.T, repo string) int {
	t.Helper()
	root := filepath.Join(repo, "binary")
	count := 0
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		count++
		return nil
	})
	return count
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
	if _, err := defaultRunCmd(context.Background(), repo, "git", "merge-base", "--is-ancestor", foreignSHA, "HEAD"); err != nil {
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
	imp.runCmd = func(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "push" {
			n := atomic.AddInt32(&pushAttempts, 1)
			if n <= 2 {
				_ = advanceRemoteWithForeignCommit(t, remote)
			}
		}
		return baseRun(ctx, dir, name, args...)
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
	imp.runCmd = func(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "push" {
			_ = advanceRemoteWithForeignCommit(t, remote)
		}
		return baseRun(ctx, dir, name, args...)
	}

	err := imp.pushWithRebase(context.Background(), repo)
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
	imp.runCmd = func(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "rebase" && !sliceContains(args, "--abort") {
			cmds.record(args)
			return nil, fmt.Errorf("injected rebase failure")
		}
		return baseRun(ctx, dir, name, args...)
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

// TestCommitFailureUnstagesBatch verifies that a failed git commit after a
// successful git add cannot leave staged-but-deleted index entries. That is the
// poison that permanently blocks rebase with "You have unstaged changes".
func TestCommitFailureUnstagesBatch(t *testing.T) {
	repo := initTempRepo(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")

	imp, _, _, _ := newTestImporter(t, nil)
	baseRun := imp.runCmd
	imp.runCmd = func(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "commit" {
			return nil, fmt.Errorf("injected commit failure")
		}
		return baseRun(ctx, dir, name, args...)
	}

	err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	})
	if err != nil {
		t.Fatalf("run failed: %v", err)
	}

	deleted := strings.TrimSpace(mustRun(t, repo, "git", "ls-files", "-d"))
	if deleted != "" {
		t.Fatalf("expected no staged-but-deleted paths after commit failure, got %q", deleted)
	}
	diffFiles := strings.TrimSpace(mustRun(t, repo, "git", "diff-files", "--name-only"))
	if diffFiles != "" {
		t.Fatalf("expected clean worktree after commit failure, got %q", diffFiles)
	}
	staged := strings.TrimSpace(mustRun(t, repo, "git", "diff", "--cached", "--name-only"))
	if staged != "" {
		t.Fatalf("expected empty index after commit failure, got %q", staged)
	}
}

// TestCommitFailureDoesNotBlockLaterRebase verifies recovery from an injected
// commit failure still leaves the repo rebaseable when the remote advances.
func TestCommitFailureDoesNotBlockLaterRebase(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")
	writeTinyJPEGColor(t, filepath.Join(srcDir, "b.jpg"), "blue")

	imp, _, _, cmds := newTestImporter(t, nil)
	baseRun := imp.runCmd
	var commitAttempts int32
	imp.runCmd = func(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
		if name == "git" && gitSubcommand(args) == "commit" {
			if atomic.AddInt32(&commitAttempts, 1) == 1 {
				return nil, fmt.Errorf("injected commit failure")
			}
		}
		return baseRun(ctx, dir, name, args...)
	}

	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
		Workers:     1,
	}); err != nil {
		t.Fatalf("first run failed: %v", err)
	}

	_ = advanceRemoteWithForeignCommit(t, remoteURL(t, repo))
	writeTinyJPEGColor(t, filepath.Join(srcDir, "c.jpg"), "green")
	if err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
		PushEvery:   1,
		Workers:     1,
	}); err != nil {
		t.Fatalf("second run failed: %v", err)
	}
	if !cmds.containsSubcmd("rebase") {
		t.Fatalf("expected rebase after remote advance, cmds=%v", cmds.snapshot())
	}
	local := strings.TrimSpace(mustRun(t, repo, "git", "rev-parse", "HEAD"))
	remote := strings.TrimSpace(mustRun(t, repo, "git", "ls-remote", "origin", "refs/heads/main"))
	remoteSHA := strings.Fields(remote)[0]
	if local != remoteSHA {
		t.Fatalf("expected local HEAD %s to match remote %s", local, remoteSHA)
	}
}

// TestBootRefusesDirtyWorktree ensures import refuses to start when tracked
// files are missing from the worktree, naming the path and the recovery command.
func TestBootRefusesDirtyWorktree(t *testing.T) {
	repo := initTempRepo(t)
	tracked := filepath.Join(repo, "tracked.txt")
	if err := os.WriteFile(tracked, []byte("tracked"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustRun(t, repo, "git", "add", "tracked.txt")
	mustRun(t, repo, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "track")
	if err := os.Remove(tracked); err != nil {
		t.Fatal(err)
	}

	srcDir := t.TempDir()
	writeTinyJPEGColor(t, filepath.Join(srcDir, "a.jpg"), "red")
	imp, _, _, _ := newTestImporter(t, nil)
	err := imp.run(context.Background(), CLI{
		Repo:        repo,
		Source:      srcDir,
		DeviceSpace: "device-a",
	})
	if err == nil {
		t.Fatal("expected boot to refuse a dirty worktree")
	}
	msg := err.Error()
	if !strings.Contains(msg, "tracked.txt") {
		t.Fatalf("expected dirty path in error, got %q", msg)
	}
	if !strings.Contains(msg, "git -C") || !strings.Contains(msg, "checkout -- .") {
		t.Fatalf("expected recovery command in error, got %q", msg)
	}
	if commitCount(t, repo) != 2 { // init + track
		t.Fatalf("expected no import commits on dirty boot, got %d", commitCount(t, repo))
	}
}

// TestPushWithRebaseRefusesDirtyWorktree ensures a dirty worktree surfaces
// actionable paths instead of git's opaque "cannot rebase" message, and never
// invokes rebase.
func TestPushWithRebaseRefusesDirtyWorktree(t *testing.T) {
	repo := initTempRepoWithRemote(t)
	tracked := filepath.Join(repo, "tracked.txt")
	if err := os.WriteFile(tracked, []byte("tracked"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustRun(t, repo, "git", "add", "tracked.txt")
	mustRun(t, repo, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "track")
	mustRun(t, repo, "git", "push")
	if err := os.Remove(tracked); err != nil {
		t.Fatal(err)
	}
	_ = advanceRemoteWithForeignCommit(t, remoteURL(t, repo))

	imp, _, _, cmds := newTestImporter(t, nil)
	err := imp.pushWithRebase(context.Background(), repo)
	if err == nil {
		t.Fatal("expected pushWithRebase to fail on dirty worktree")
	}
	if !strings.Contains(err.Error(), "tracked.txt") {
		t.Fatalf("expected dirty path in error, got %q", err)
	}
	if cmds.containsSubcmd("rebase") {
		t.Fatalf("expected no rebase on dirty worktree, cmds=%v", cmds.snapshot())
	}
}

// TestRunCmdTeeUsesOwnProcessGroup pins that children are started in a new
// process group so a terminal Ctrl+C delivered to the importer's group cannot
// kill an in-flight git commit that still belongs to the flush stage.
func TestRunCmdTeeUsesOwnProcessGroup(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires /proc to inspect child process group")
	}
	// Inspect the shell itself ($$), not a grandchild: Setpgid applies to the
	// process runCmdTee starts. /proc/$$/stat fields: pid (1) and pgid (5).
	out, err := runCmdTee(nil, context.Background(), "", "sh", "-c",
		`awk '{print $1, $5}' /proc/$$/stat`)
	if err != nil {
		t.Fatalf("runCmdTee failed: %v", err)
	}
	fields := strings.Fields(string(out))
	if len(fields) != 2 {
		t.Fatalf("expected pid pgid, got %q", out)
	}
	if fields[0] != fields[1] {
		t.Fatalf("expected child in own process group (pid==pgid), got pid=%s pgid=%s", fields[0], fields[1])
	}
	parentPGID, err := syscall.Getpgid(os.Getpid())
	if err != nil {
		t.Fatalf("Getpgid: %v", err)
	}
	childPGID, err := strconv.Atoi(fields[1])
	if err != nil {
		t.Fatalf("parse pgid: %v", err)
	}
	if childPGID == parentPGID {
		t.Fatalf("expected child pgid %d to differ from parent pgid %d", childPGID, parentPGID)
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
	run := func(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
		if hook != nil {
			hook(name, args)
		}
		if name == "git" {
			cmds.record(args)
			if gitSubcommand(args) == "push" {
				atomic.AddInt32(&pushCalls, 1)
			}
		}
		return imp.execCmd(ctx, dir, name, args...)
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
	gittest.DisableAutoMaintenance(t, remote)
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
	_, err := defaultRunCmd(context.Background(), "", "ffmpeg",
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
	_, err := defaultRunCmd(context.Background(), "", "ffmpeg",
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
	_, err := defaultRunCmd(context.Background(), "", "ffmpeg",
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
	out, err := defaultRunCmd(context.Background(), dir, name, args...)
	if err != nil {
		t.Fatalf("%s %v failed: %v", name, args, err)
	}
	return string(out)
}
