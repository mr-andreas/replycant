package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	imagedraw "image/draw"
	"image/jpeg"
	_ "image/png"
	"io"
	"io/fs"
	"mime"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alecthomas/kong"
	"github.com/bep/imagemeta"
	_ "github.com/gen2brain/heic"
	"github.com/google/uuid"
	xdraw "golang.org/x/image/draw"
	"gopkg.in/yaml.v3"
)

const (
	apiVersion = "media.replycant.com/v1alpha1"
)

var (
	photoExts = map[string]struct{}{
		".jpg": {}, ".jpeg": {}, ".png": {}, ".heic": {}, ".heif": {},
	}
	videoExts = map[string]struct{}{
		".mp4": {}, ".mov": {}, ".m4v": {}, ".avi": {}, ".mkv": {},
	}
)

// CLI defines importer arguments to keep invocation simple and explicit.
type CLI struct {
	Repo        string `arg:"" help:"Path to the cloned replycant repository."`
	Source      string `arg:"" help:"Path to directory of files to import (recursive)."`
	DeviceSpace string `arg:"" help:"Target device space name."`
	PushEvery   int    `name:"push-every" default:"0" help:"Push every N commits in the background. 0 disables periodic push."`
	Workers     int    `name:"workers" default:"0" help:"Number of parallel import workers. 0 uses all CPUs."`
	Verbose     bool   `name:"verbose" short:"v" help:"Mirror git push/fetch/rebase output, including pre-push LFS upload progress."`
}

// ManifestMetadata carries common metadata fields required by the protocol.
type ManifestMetadata struct {
	Name        string `yaml:"name"`
	DeviceSpace string `yaml:"deviceSpace"`
}

// OriginalLocation stores optional capture location extracted from media metadata.
type OriginalLocation struct {
	Latitude  float64  `yaml:"latitude"`
	Longitude float64  `yaml:"longitude"`
	Altitude  *float64 `yaml:"altitude,omitempty"`
}

// OriginalSpec carries core media metadata used for dedup and browsing.
type OriginalSpec struct {
	ID             string            `yaml:"id"`
	SHA256         string            `yaml:"sha256"`
	Path           string            `yaml:"path"`
	Filesize       int64             `yaml:"filesize"`
	MediaType      string            `yaml:"mediaType"`
	Width          int               `yaml:"width"`
	Height         int               `yaml:"height"`
	ModifiedAt     string            `yaml:"modifiedAt,omitempty"`
	Duration       *float64          `yaml:"duration,omitempty"`
	MimeType       string            `yaml:"mimeType,omitempty"`
	IsFavorite     bool              `yaml:"isFavorite"`
	IsHidden       bool              `yaml:"isHidden"`
	CreatedAt      string            `yaml:"createdAt"`
	TakenAt        string            `yaml:"takenAt,omitempty"`
	GuessedTakenAt string            `yaml:"guessedTakenAt,omitempty"`
	Location       *OriginalLocation `yaml:"location,omitempty"`
}

// OriginalManifest stores protocol-compatible metadata for one original file.
type OriginalManifest struct {
	APIVersion string           `yaml:"apiVersion"`
	Kind       string           `yaml:"kind"`
	Metadata   ManifestMetadata `yaml:"metadata"`
	Spec       OriginalSpec     `yaml:"spec"`
	Status     map[string]any   `yaml:"status"`
}

// ThumbnailEntry describes one generated thumbnail variant.
type ThumbnailEntry struct {
	Name     string `yaml:"name"`
	SHA256   string `yaml:"sha256"`
	Width    int    `yaml:"width"`
	Height   int    `yaml:"height"`
	Filesize int64  `yaml:"filesize"`
}

// ThumbnailSetSpec groups all thumbnail variants for an original.
type ThumbnailSetSpec struct {
	OriginalRef string           `yaml:"originalRef"`
	Thumbnails  []ThumbnailEntry `yaml:"thumbnails"`
}

// ThumbnailSetManifest stores protocol-compatible metadata for one thumbnail set.
type ThumbnailSetManifest struct {
	APIVersion string           `yaml:"apiVersion"`
	Kind       string           `yaml:"kind"`
	Metadata   ManifestMetadata `yaml:"metadata"`
	Spec       ThumbnailSetSpec `yaml:"spec"`
	Status     map[string]any   `yaml:"status"`
}

// importer dependencies are injectable to make behavior testable end-to-end.
type importer struct {
	stderr io.Writer
	// verboseOut receives live child-process stderr for remote git operations so a
	// multi-minute LFS upload reports progress instead of looking like a hang.
	verboseOut           io.Writer
	log                  func(format string, args ...any) (int, error)
	runCmd               func(dir string, name string, args ...string) ([]byte, error)
	newUUID              func() string
	now                  func() time.Time
	extractPhotoMetadata func(path string) (string, *OriginalLocation, int)
	gitMu                sync.Mutex
	shaMu                sync.Mutex
}

// mediaMeta is normalized metadata from ffprobe needed for manifests/thumbnails.
type mediaMeta struct {
	width        int
	height       int
	duration     *float64
	mimeType     string
	creationTime string
}

// thumbSpec defines one thumbnail output size requirement.
type thumbSpec struct {
	suffix string
	size   int
	square bool
	scaler xdraw.Interpolator
}

// main runs the CLI and exits non-zero only for fatal configuration/runtime errors.
func main() {
	if err := runCLI(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// runCLI parses CLI args and executes the importer with signal-aware shutdown.
func runCLI() error {
	var cli CLI
	parser, err := kong.New(
		&cli,
		kong.Name("replycant-importer"),
		kong.Description("Import photos/videos into a replycant repository."),
		kong.UsageOnError(),
	)
	if err != nil {
		return err
	}
	if _, err := parser.Parse(os.Args[1:]); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	imp := &importer{
		stderr:               os.Stderr,
		log:                  fmt.Printf,
		newUUID:              func() string { return uuid.NewString() },
		now:                  time.Now,
		extractPhotoMetadata: extractImageMetadata,
	}
	imp.runCmd = imp.execCmd
	return imp.run(ctx, cli)
}

// run validates setup, imports recursively, and keeps processing on per-file errors.
func (i *importer) run(ctx context.Context, cli CLI) error {
	if i.log == nil {
		i.log = fmt.Printf
	}
	// Set before any goroutine starts so command mirroring needs no synchronization.
	if cli.Verbose {
		i.verboseOut = i.stderr
	}

	if cli.PushEvery < 0 {
		return fmt.Errorf("push-every must be >= 0")
	}
	if cli.Workers < 0 {
		return fmt.Errorf("workers must be >= 0")
	}
	if strings.TrimSpace(cli.DeviceSpace) == "" {
		return fmt.Errorf("device-space must not be empty")
	}

	repoAbs, err := filepath.Abs(cli.Repo)
	if err != nil {
		return fmt.Errorf("repo path: %w", err)
	}
	srcAbs, err := filepath.Abs(cli.Source)
	if err != nil {
		return fmt.Errorf("source path: %w", err)
	}

	_, _ = i.log("boot: validating repository %s\n", repoAbs)
	if err := i.ensureGitRepo(repoAbs); err != nil {
		return err
	}
	_, _ = i.log("boot: repository ok\n")
	if st, err := os.Stat(srcAbs); err != nil || !st.IsDir() {
		return fmt.Errorf("source path must be an existing directory")
	}
	_, _ = i.log("boot: source directory %s\n", srcAbs)
	_, _ = i.log("boot: checking required tools\n")
	if err := i.ensureTool("ffmpeg"); err != nil {
		return err
	}
	if err := i.ensureTool("ffprobe"); err != nil {
		return err
	}
	_, _ = i.log("boot: tools ready (ffmpeg, ffprobe)\n")

	_, _ = i.log("boot: loading existing manifests\n")
	knownSHAs, knownPathSizes, err := i.loadExistingSHAs(repoAbs)
	if err != nil {
		return err
	}
	_, _ = i.log("boot: loaded %d known sha256 values\n", len(knownSHAs))

	_, _ = i.log("boot: scanning source files\n")
	files, err := collectSourceFiles(srcAbs)
	if err != nil {
		return err
	}
	_, _ = i.log("boot: found %d source files\n", len(files))

	pushCh := make(chan struct{}, 32)
	var pushWG sync.WaitGroup
	if cli.PushEvery > 0 {
		pushWG.Add(1)
		go func() {
			defer pushWG.Done()
			i.pushLoop(repoAbs, cli.PushEvery, pushCh)
		}()
	}

	workers := cli.Workers
	if workers <= 0 {
		workers = runtime.NumCPU()
	}
	if workers < 1 {
		workers = 1
	}

	workCh := make(chan int, workers)
	commitCh := make(chan *preparedImport, workers*2)
	var workerWG sync.WaitGroup
	var commitWG sync.WaitGroup
	var logMu sync.Mutex
	commitWG.Add(1)
	go func() {
		defer commitWG.Done()
		for {
			first, ok := <-commitCh
			if !ok {
				return
			}
			if first == nil {
				continue
			}

			batch := []*preparedImport{first}
			for {
				select {
				case next, ok := <-commitCh:
					if !ok {
						goto commitBatch
					}
					if next != nil {
						batch = append(batch, next)
					}
				default:
					goto commitBatch
				}
			}

		commitBatch:
			commitStart := i.now()
			if err := i.gitCommit(repoAbs, batch); err != nil {
				for _, prepared := range batch {
					logMu.Lock()
					fmt.Fprintf(i.stderr, "error importing %s: %v\n", prepared.sourceName, err)
					logMu.Unlock()
					if prepared.reservedSHA != "" {
						i.shaMu.Lock()
						delete(knownSHAs, prepared.reservedSHA)
						i.shaMu.Unlock()
					}
					for _, p := range prepared.writtenPaths {
						_ = os.Remove(p)
					}
				}
				continue
			}
			logMu.Lock()
			_, _ = i.log(
				"commit: %d file(s) in %s\n",
				len(batch),
				i.now().Sub(commitStart).Round(time.Millisecond),
			)
			logMu.Unlock()
			for _, prepared := range batch {
				logMu.Lock()
				_, _ = i.log("[%d/%d] %s imported\n", prepared.index+1, len(files), prepared.sourceName)
				logMu.Unlock()
				if cli.PushEvery > 0 {
					pushCh <- struct{}{}
				}
			}
		}
	}()
	for w := 0; w < workers; w++ {
		workerWG.Add(1)
		go func() {
			defer workerWG.Done()
			for idx := range workCh {
				if ctx.Err() != nil {
					continue
				}
				file := files[idx]
				prepared, skipped, err := i.prepareFile(repoAbs, cli.DeviceSpace, file, knownSHAs, knownPathSizes)
				if err != nil {
					logMu.Lock()
					fmt.Fprintf(i.stderr, "error importing %s: %v\n", file, err)
					logMu.Unlock()
					continue
				}
				if skipped {
					logMu.Lock()
					_, _ = i.log("[%d/%d] %s (duplicate, skipped)\n", idx+1, len(files), filepath.Base(file))
					logMu.Unlock()
					continue
				}
				if prepared == nil {
					continue
				}
				prepared.index = idx
				select {
				case commitCh <- prepared:
				case <-ctx.Done():
				}
			}
		}()
	}
	for idx := 0; idx < len(files); idx++ {
		if ctx.Err() != nil {
			break
		}
		workCh <- idx
	}
	close(workCh)
	workerWG.Wait()
	close(commitCh)
	commitWG.Wait()

	close(pushCh)
	pushWG.Wait()
	// Flush remaining commits (and recover from a late push rejection) so a finished
	// import does not leave work local-only when periodic push is enabled.
	if cli.PushEvery > 0 {
		i.gitMu.Lock()
		err := i.pushWithRebase(repoAbs)
		i.gitMu.Unlock()
		if err != nil {
			return fmt.Errorf("final push failed: %w", err)
		}
	}
	return nil
}

// ensureGitRepo validates the repo arg points at an existing git worktree.
func (i *importer) ensureGitRepo(repoPath string) error {
	out, err := i.runCmd(repoPath, "git", "rev-parse", "--is-inside-work-tree")
	if err != nil {
		return fmt.Errorf("repo path is not a git repository: %w", err)
	}
	if strings.TrimSpace(string(out)) != "true" {
		return fmt.Errorf("repo path is not a git worktree")
	}
	return nil
}

// ensureTool fails fast when external tool dependencies are missing from PATH.
func (i *importer) ensureTool(name string) error {
	if _, err := exec.LookPath(name); err != nil {
		return fmt.Errorf("%s not found in PATH", name)
	}
	return nil
}

// collectSourceFiles recursively enumerates supported media files in stable order.
func collectSourceFiles(root string) ([]string, error) {
	var out []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		if mediaTypeFromPath(path) == "" {
			return nil
		}
		out = append(out, path)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

// loadExistingSHAs indexes all existing Original manifests across all device spaces.
func (i *importer) loadExistingSHAs(repoPath string) (map[string]struct{}, map[string]int64, error) {
	ret := map[string]struct{}{}
	pathSizes := map[string]int64{}
	base := filepath.Join(repoPath, "manifests")
	if _, err := os.Stat(base); errors.Is(err, os.ErrNotExist) {
		return ret, pathSizes, nil
	}
	err := filepath.WalkDir(base, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || filepath.Ext(path) != ".yaml" {
			return nil
		}
		norm := filepath.ToSlash(path)
		if !strings.Contains(norm, "/media.replycant.com/v1alpha1/Original/") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var parsed struct {
			Spec struct {
				SHA256   string `yaml:"sha256"`
				Path     string `yaml:"path"`
				Filesize int64  `yaml:"filesize"`
			} `yaml:"spec"`
		}
		if err := yaml.Unmarshal(b, &parsed); err != nil {
			return nil
		}
		sha := strings.TrimSpace(parsed.Spec.SHA256)
		if sha != "" {
			ret[sha] = struct{}{}
		}
		manifestPath := strings.TrimSpace(parsed.Spec.Path)
		if manifestPath != "" {
			pathSizes[manifestPath] = parsed.Spec.Filesize
		}
		return nil
	})
	return ret, pathSizes, err
}

type preparedImport struct {
	sourceName   string
	writtenPaths []string
	reservedSHA  string
	index        int
}

// prepareFile writes one file's artifacts and returns data for later commit.
func (i *importer) prepareFile(repoPath, deviceSpace, sourcePath string, knownSHAs map[string]struct{}, knownPathSizes map[string]int64) (result *preparedImport, skipped bool, retErr error) {
	var writtenPaths []string
	reservedSHA := ""
	defer func() {
		if retErr == nil {
			return
		}
		if reservedSHA != "" {
			i.shaMu.Lock()
			delete(knownSHAs, reservedSHA)
			i.shaMu.Unlock()
		}
		for _, p := range writtenPaths {
			_ = os.Remove(p)
		}
	}()

	if knownSize, ok := knownPathSizes[sourcePath]; ok {
		if st, err := os.Stat(sourcePath); err == nil && st.Size() == knownSize {
			return nil, true, nil
		}
	}

	sum, size, err := fileSHAAndSize(sourcePath)
	if err != nil {
		return nil, false, err
	}
	i.shaMu.Lock()
	if _, ok := knownSHAs[sum]; ok {
		i.shaMu.Unlock()
		return nil, true, nil
	}
	knownSHAs[sum] = struct{}{}
	reservedSHA = sum
	i.shaMu.Unlock()

	mediaType := mediaTypeFromPath(sourcePath)
	if mediaType == "" {
		i.shaMu.Lock()
		delete(knownSHAs, reservedSHA)
		i.shaMu.Unlock()
		reservedSHA = ""
		return nil, true, nil
	}

	meta, err := i.probeMedia(sourcePath, mediaType)
	if err != nil {
		return nil, false, err
	}

	name := strings.ToLower(i.newUUID())
	originalRef := fmt.Sprintf("%s/%s/Original/%s", deviceSpace, apiVersion, name)
	manifestPath := filepath.Join(repoPath, "manifests", deviceSpace, apiVersion, "Original", shardName(name)+".yaml")
	binaryPath := filepath.Join(repoPath, "binary", deviceSpace, apiVersion, "Original", shardName(name))

	if err := copyFile(sourcePath, binaryPath); err != nil {
		return nil, false, err
	}
	writtenPaths = append(writtenPaths, binaryPath)

	modifiedAt := i.now().UTC().Format(time.RFC3339)
	if st, err := os.Stat(sourcePath); err == nil {
		modifiedAt = st.ModTime().UTC().Format(time.RFC3339)
	}
	createdAt := i.now().UTC().Format(time.RFC3339)
	takenAt := meta.creationTime
	location := (*OriginalLocation)(nil)
	orientation := 1
	if mediaType == "photo" {
		extractFn := i.extractPhotoMetadata
		if extractFn == nil {
			extractFn = extractImageMetadata
		}
		extractedTakenAt, extractedLocation, extractedOrientation := extractFn(sourcePath)
		if extractedTakenAt != "" {
			takenAt = extractedTakenAt
		}
		location = extractedLocation
		orientation = extractedOrientation
	}
	guessedTakenAt := takenAt
	if guessedTakenAt == "" {
		guessedTakenAt = modifiedAt
	}
	originalWidth := meta.width
	originalHeight := meta.height
	var photoSrc image.Image
	if mediaType == "photo" {
		photoSrc, err = decodeOrientedImage(sourcePath, orientation)
		if err != nil {
			return nil, false, err
		}
		bounds := photoSrc.Bounds()
		originalWidth = bounds.Dx()
		originalHeight = bounds.Dy()
	}

	om := OriginalManifest{
		APIVersion: apiVersion,
		Kind:       "Original",
		Metadata: ManifestMetadata{
			Name:        name,
			DeviceSpace: deviceSpace,
		},
		Spec: OriginalSpec{
			ID:             name,
			SHA256:         sum,
			Path:           sourcePath,
			Filesize:       size,
			MediaType:      mediaType,
			Width:          originalWidth,
			Height:         originalHeight,
			ModifiedAt:     modifiedAt,
			Duration:       meta.duration,
			MimeType:       meta.mimeType,
			IsFavorite:     false,
			IsHidden:       false,
			CreatedAt:      createdAt,
			TakenAt:        takenAt,
			GuessedTakenAt: guessedTakenAt,
			Location:       location,
		},
		Status: map[string]any{},
	}
	if err := writeYAMLFile(manifestPath, om); err != nil {
		return nil, false, err
	}
	writtenPaths = append(writtenPaths, manifestPath)

	thumbs, err := i.generateThumbnails(repoPath, deviceSpace, name, sourcePath, mediaType, meta.duration, originalRef, photoSrc)
	if err != nil {
		return nil, false, err
	}
	writtenPaths = append(writtenPaths, thumbs.binaryPaths...)
	if err := writeYAMLFile(thumbs.manifestPath, thumbs.manifest); err != nil {
		return nil, false, err
	}
	writtenPaths = append(writtenPaths, thumbs.manifestPath)
	return &preparedImport{
		sourceName:   filepath.Base(sourcePath),
		writtenPaths: writtenPaths,
		reservedSHA:  reservedSHA,
	}, false, nil
}

type generatedThumbnails struct {
	manifestPath string
	binaryPaths  []string
	manifest     ThumbnailSetManifest
}

// generateThumbnails creates all variants and returns their manifest data.
func (i *importer) generateThumbnails(repoPath, deviceSpace, originalName, sourcePath, mediaType string, duration *float64, originalRef string, photoSrc image.Image) (generatedThumbnails, error) {
	specs := []thumbSpec{
		{suffix: "150x150", size: 150, square: true, scaler: xdraw.ApproxBiLinear},
		{suffix: "225x225", size: 225, square: true, scaler: xdraw.ApproxBiLinear},
		{suffix: "1024", size: 1024, square: false, scaler: xdraw.CatmullRom},
	}
	out := generatedThumbnails{
		binaryPaths: make([]string, 0, len(specs)),
		manifest: ThumbnailSetManifest{
			APIVersion: apiVersion,
			Kind:       "ThumbnailSet",
			Metadata: ManifestMetadata{
				Name:        originalName + "-thumbs",
				DeviceSpace: deviceSpace,
			},
			Spec: ThumbnailSetSpec{
				OriginalRef: originalRef,
				Thumbnails:  make([]ThumbnailEntry, 0, len(specs)),
			},
			Status: map[string]any{},
		},
	}
	out.manifestPath = filepath.Join(
		repoPath,
		"manifests",
		deviceSpace,
		apiVersion,
		"ThumbnailSet",
		shardName(out.manifest.Metadata.Name)+".yaml",
	)
	for _, s := range specs {
		thumbName := fmt.Sprintf("%s-thumb-%s", originalName, s.suffix)
		thumbBinaryPath := filepath.Join(repoPath, "binary", deviceSpace, apiVersion, "ThumbnailSet", shardName(thumbName))
		if err := os.MkdirAll(filepath.Dir(thumbBinaryPath), 0o755); err != nil {
			return generatedThumbnails{}, err
		}
		thumbW, thumbH := 0, 0
		if mediaType == "photo" {
			w, h, err := scalePhotoThumbnail(photoSrc, thumbBinaryPath, s)
			if err != nil {
				return generatedThumbnails{}, err
			}
			thumbW, thumbH = w, h
		} else {
			if err := i.makeThumbnail(sourcePath, thumbBinaryPath, mediaType, duration, s); err != nil {
				return generatedThumbnails{}, err
			}
		}
		sum, size, err := fileSHAAndSize(thumbBinaryPath)
		if err != nil {
			return generatedThumbnails{}, err
		}
		if mediaType == "video" {
			thumbMeta, err := i.probeMedia(thumbBinaryPath, "video")
			if err != nil {
				return generatedThumbnails{}, err
			}
			thumbW = thumbMeta.width
			thumbH = thumbMeta.height
		}
		out.binaryPaths = append(out.binaryPaths, thumbBinaryPath)
		out.manifest.Spec.Thumbnails = append(out.manifest.Spec.Thumbnails, ThumbnailEntry{
			Name:     thumbName,
			SHA256:   sum,
			Width:    thumbW,
			Height:   thumbH,
			Filesize: size,
		})
	}
	return out, nil
}

// makeThumbnail renders one thumbnail variant as JPEG.
func (i *importer) makeThumbnail(inputPath, outputPath, mediaType string, duration *float64, spec thumbSpec) error {
	filter := ""
	if spec.square {
		filter = fmt.Sprintf("scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d", spec.size, spec.size, spec.size, spec.size)
	} else {
		filter = fmt.Sprintf("scale='if(gte(iw,ih),%d,-2)':'if(gte(ih,iw),%d,-2)'", spec.size, spec.size)
	}

	args := []string{"-y", "-loglevel", "error", "-i", inputPath}
	if mediaType == "video" {
		seek := "0"
		if duration != nil && *duration > 2 {
			seek = fmt.Sprintf("%.3f", *duration/2)
		}
		args = append(args, "-ss", seek)
	}
	tmpPath := outputPath + ".jpg"
	args = append(args, "-vf", filter, "-frames:v", "1", "-q:v", "2")
	if mediaType == "video" {
		args = append(args, "-pix_fmt", "yuvj420p")
	}
	args = append(args, tmpPath)
	if _, err := i.runCmd("", "ffmpeg", args...); err != nil {
		return err
	}
	return os.Rename(tmpPath, outputPath)
}

func scalePhotoThumbnail(src image.Image, outputPath string, spec thumbSpec) (int, int, error) {
	srcBounds := src.Bounds()
	if srcBounds.Dx() == 0 || srcBounds.Dy() == 0 {
		return 0, 0, fmt.Errorf("invalid image dimensions")
	}

	scaleSrc := src
	dstW, dstH := spec.size, spec.size
	if spec.square {
		side := srcBounds.Dx()
		if srcBounds.Dy() < side {
			side = srcBounds.Dy()
		}
		x0 := srcBounds.Min.X + (srcBounds.Dx()-side)/2
		y0 := srcBounds.Min.Y + (srcBounds.Dy()-side)/2
		scaleSrc = cropImage(src, image.Rect(x0, y0, x0+side, y0+side))
	} else if srcBounds.Dx() >= srcBounds.Dy() {
		dstH = srcBounds.Dy() * spec.size / srcBounds.Dx()
		if dstH < 1 {
			dstH = 1
		}
	} else {
		dstW = srcBounds.Dx() * spec.size / srcBounds.Dy()
		if dstW < 1 {
			dstW = 1
		}
	}

	dst := image.NewRGBA(image.Rect(0, 0, dstW, dstH))
	spec.scaler.Scale(dst, dst.Bounds(), scaleSrc, scaleSrc.Bounds(), xdraw.Over, nil)

	out, err := os.Create(outputPath)
	if err != nil {
		return 0, 0, err
	}
	defer out.Close()

	if err := jpeg.Encode(out, dst, &jpeg.Options{Quality: 85}); err != nil {
		return 0, 0, err
	}
	if err := out.Close(); err != nil {
		return 0, 0, err
	}
	return dstW, dstH, nil
}

func cropImage(src image.Image, r image.Rectangle) *image.NRGBA {
	dst := image.NewNRGBA(image.Rect(0, 0, r.Dx(), r.Dy()))
	imagedraw.Draw(dst, dst.Bounds(), src, r.Min, imagedraw.Src)
	return dst
}

func applyOrientation(src image.Image, orientation int) image.Image {
	if orientation <= 1 || orientation > 8 {
		return src
	}

	nrgba, ok := src.(*image.NRGBA)
	if !ok {
		sb := src.Bounds()
		nrgba = image.NewNRGBA(sb)
		imagedraw.Draw(nrgba, sb, src, sb.Min, imagedraw.Src)
	}

	sb := nrgba.Bounds()
	sw, sh := sb.Dx(), sb.Dy()
	if sw == 0 || sh == 0 {
		return src
	}

	dw, dh := sw, sh
	if orientation >= 5 {
		dw, dh = sh, sw
	}

	dst := image.NewNRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < dh; y++ {
		for x := 0; x < dw; x++ {
			sx, sy := sourcePixelForOrientation(orientation, x, y, sw, sh)
			srcOffset := nrgba.PixOffset(sb.Min.X+sx, sb.Min.Y+sy)
			dstOffset := dst.PixOffset(x, y)
			copy(dst.Pix[dstOffset:dstOffset+4], nrgba.Pix[srcOffset:srcOffset+4])
		}
	}
	return dst
}

func sourcePixelForOrientation(orientation, x, y, sw, sh int) (int, int) {
	switch orientation {
	case 2:
		return sw - 1 - x, y
	case 3:
		return sw - 1 - x, sh - 1 - y
	case 4:
		return x, sh - 1 - y
	case 5:
		return y, x
	case 6:
		return y, sh - 1 - x
	case 7:
		return sw - 1 - y, sh - 1 - x
	case 8:
		return sw - 1 - y, x
	default:
		return x, y
	}
}

// probeMedia reads dimensions/duration/mime using ffprobe and file extension fallback.
func (i *importer) probeMedia(path string, mediaType string) (mediaMeta, error) {
	args := []string{
		"-v", "error",
		"-print_format", "json",
		"-show_streams",
		"-show_format",
		path,
	}
	out, err := i.runCmd("", "ffprobe", args...)
	if err != nil {
		return mediaMeta{}, fmt.Errorf("ffprobe failed: %w", err)
	}

	var parsed struct {
		Streams []struct {
			CodecType    string `json:"codec_type"`
			Width        int    `json:"width"`
			Height       int    `json:"height"`
			Duration     string `json:"duration"`
			SideDataList []struct {
				Rotation *float64 `json:"rotation"`
			} `json:"side_data_list"`
			Tags struct {
				Rotate string `json:"rotate"`
			} `json:"tags"`
		} `json:"streams"`
		Format struct {
			Duration string `json:"duration"`
			Tags     struct {
				CreationTime string `json:"creation_time"`
			} `json:"tags"`
		} `json:"format"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return mediaMeta{}, fmt.Errorf("ffprobe json parse failed: %w", err)
	}

	var mm mediaMeta
	for _, s := range parsed.Streams {
		if s.CodecType != "video" {
			continue
		}
		mm.width = s.Width
		mm.height = s.Height
		if rotationQuarterTurns(s.SideDataList, s.Tags.Rotate)%2 != 0 {
			mm.width, mm.height = mm.height, mm.width
		}
		if d, err := parseDuration(s.Duration); err == nil && d > 0 {
			mm.duration = &d
		}
		break
	}
	if mm.duration == nil {
		if d, err := parseDuration(parsed.Format.Duration); err == nil && d > 0 {
			mm.duration = &d
		}
	}
	mm.creationTime = parseTimestamp(parsed.Format.Tags.CreationTime)
	if mediaType == "video" && (mm.width == 0 || mm.height == 0) {
		return mediaMeta{}, fmt.Errorf("media dimensions missing")
	}
	mm.mimeType = mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
	if mm.mimeType == "" {
		mm.mimeType = "application/octet-stream"
	}
	return mm, nil
}

// gitCommit stores one atomic import commit for a batch of prepared files.
func (i *importer) gitCommit(repoPath string, batch []*preparedImport) error {
	if len(batch) == 0 {
		return nil
	}
	i.gitMu.Lock()
	defer i.gitMu.Unlock()

	addArgs := []string{"add"}
	seen := map[string]struct{}{}
	var sourceNames []string
	for _, prepared := range batch {
		sourceNames = append(sourceNames, prepared.sourceName)
		for _, p := range prepared.writtenPaths {
			rel, err := filepath.Rel(repoPath, p)
			if err != nil {
				return fmt.Errorf("git add path %s: %w", p, err)
			}
			rel = filepath.ToSlash(rel)
			if _, ok := seen[rel]; ok {
				continue
			}
			seen[rel] = struct{}{}
			addArgs = append(addArgs, rel)
		}
	}
	if len(addArgs) == 1 {
		return fmt.Errorf("git add failed: no paths to add")
	}
	if _, err := i.runCmd(repoPath, "git", addArgs...); err != nil {
		return fmt.Errorf("git add failed: %w", err)
	}
	msg := fmt.Sprintf("import: %s", strings.Join(sourceNames, ", "))
	commitArgs := []string{
		"-c", "user.name=Replycant Importer",
		"-c", "user.email=importer@replycant.com",
		"commit", "-m", msg, "--author", "Replycant Importer <importer@replycant.com>",
	}
	if _, err := i.runCmd(repoPath, "git", commitArgs...); err != nil {
		return fmt.Errorf("git commit failed: %w", err)
	}
	return nil
}

// pushLoop periodically runs git push based on successful commit notifications.
func (i *importer) pushLoop(repoPath string, every int, ch <-chan struct{}) {
	if every <= 0 {
		return
	}
	count := 0
	for range ch {
		count++
		if count < every {
			continue
		}
		count = 0
		i.gitMu.Lock()
		err := i.pushWithRebase(repoPath)
		i.gitMu.Unlock()
		if err != nil {
			fmt.Fprintf(i.stderr, "error pushing repository: %v\n", err)
		}
	}
}

// pushRebaseMaxAttempts caps push → fetch → rebase retries so a steadily advancing
// remote (e.g. iOS sync) cannot stall the import forever, while still covering a
// few consecutive race losses.
const pushRebaseMaxAttempts = 5

// pushWithRebase pushes and, on rejection, fetches and rebases before retrying.
// This recovers from concurrent remote advances without rewriting LFS/binary content:
// rebase reuses existing blobs/trees, and merge-ort plus --no-autostash avoid smudging
// the whole unpushed binary backlog into the worktree. Retries are bounded so a
// continuously moving remote eventually surfaces a hard error.
func (i *importer) pushWithRebase(repoPath string) error {
	start := i.now()
	_, _ = i.log("push: start pending_commits=%s\n", i.pendingCommitLabel(repoPath))
	var lastPushErr error
	for attempt := 1; attempt <= pushRebaseMaxAttempts; attempt++ {
		_, err := i.runCmd(repoPath, "git", "push")
		if err == nil {
			_, _ = i.log("push: done attempts=%d elapsed=%s\n", attempt, i.now().Sub(start).Round(time.Millisecond))
			return nil
		}
		lastPushErr = err
		if attempt == pushRebaseMaxAttempts {
			break
		}
		_, _ = i.log(
			"push: attempt %d/%d rejected: %s\n",
			attempt,
			pushRebaseMaxAttempts,
			summarizeCommandError(err),
		)

		branchOut, branchErr := i.runCmd(repoPath, "git", "rev-parse", "--abbrev-ref", "HEAD")
		if branchErr != nil {
			return lastPushErr
		}
		branch := strings.TrimSpace(string(branchOut))
		if branch == "" || branch == "HEAD" {
			return lastPushErr
		}
		// Fetch failure usually means the original push failed for network reasons,
		// not a non-fast-forward rejection — skip rebase and surface the push error.
		if _, fetchErr := i.runCmd(repoPath, "git", "fetch", "origin"); fetchErr != nil {
			return lastPushErr
		}
		rebaseArgs := []string{
			"-c", "user.name=Replycant Importer",
			"-c", "user.email=importer@replycant.com",
			"-c", "rebase.backend=merge",
			"rebase", "--no-autostash", "origin/" + branch,
		}
		if _, rebaseErr := i.runCmd(repoPath, "git", rebaseArgs...); rebaseErr != nil {
			_, _ = i.runCmd(repoPath, "git", "rebase", "--abort")
			return fmt.Errorf("rebase after failed push: %w", rebaseErr)
		}
		_, _ = i.log("push: rebased onto origin/%s; retrying\n", branch)
	}
	_, _ = i.log(
		"push: failed after %d attempts elapsed=%s\n",
		pushRebaseMaxAttempts,
		i.now().Sub(start).Round(time.Millisecond),
	)
	return lastPushErr
}

// pendingCommitLabel reports how many local commits are missing from the tracked
// remote branch so push logs show the backlog size. Best effort: a missing or
// stale upstream ref must never fail the push, so it degrades to "unknown".
func (i *importer) pendingCommitLabel(repoPath string) string {
	out, err := i.runCmd(repoPath, "git", "rev-list", "--count", "@{upstream}..HEAD")
	if err != nil {
		return "unknown"
	}
	count := strings.TrimSpace(string(out))
	if count == "" {
		return "unknown"
	}
	return count
}

// summarizeCommandError collapses multi-line git stderr into one log-friendly line.
func summarizeCommandError(err error) string {
	const maxLen = 200
	line := strings.Join(strings.Fields(err.Error()), " ")
	if len(line) > maxLen {
		return line[:maxLen] + "..."
	}
	return line
}

// mediaTypeFromPath classifies supported import types from file extension.
func mediaTypeFromPath(path string) string {
	ext := strings.ToLower(filepath.Ext(path))
	if _, ok := photoExts[ext]; ok {
		return "photo"
	}
	if _, ok := videoExts[ext]; ok {
		return "video"
	}
	return ""
}

// shardName keeps per-directory git tree size bounded by spreading names across two prefix directories.
func shardName(name string) string {
	if len(name) < 5 {
		return name
	}
	return name[:2] + "/" + name[2:4] + "/" + name[4:]
}

// fileSHAAndSize computes deterministic content hash and size for dedup checks.
func fileSHAAndSize(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()

	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return fmt.Sprintf("%x", h.Sum(nil)), n, nil
}

// writeYAMLFile persists protocol manifests with parent directory creation.
func writeYAMLFile(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := yaml.Marshal(v)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

// copyFile writes one file payload into destination path with parent creation.
func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}

// parseDuration accepts ffprobe decimal durations and converts to seconds.
func parseDuration(v string) (float64, error) {
	if strings.TrimSpace(v) == "" || v == "N/A" {
		return 0, fmt.Errorf("duration missing")
	}
	return strconv.ParseFloat(v, 64)
}

// extractImageMetadata reads capture date/orientation and optional GPS from image metadata.
func extractImageMetadata(path string) (takenAt string, loc *OriginalLocation, orientation int) {
	format, ok := imageFormatFromPath(path)
	if !ok {
		return "", nil, 1
	}

	f, err := os.Open(path)
	if err != nil {
		return "", nil, 1
	}
	defer f.Close()

	var tags imagemeta.Tags
	_, err = imagemeta.Decode(imagemeta.Options{
		R:           f,
		ImageFormat: format,
		Sources:     imagemeta.EXIF | imagemeta.XMP | imagemeta.IPTC,
		HandleTag: func(info imagemeta.TagInfo) error {
			tags.Add(info)
			return nil
		},
	})
	if err != nil {
		return "", nil, 1
	}
	orientation = 1

	if dt, err := tags.GetDateTime(); err == nil && !dt.IsZero() {
		takenAt = dt.UTC().Format(time.RFC3339)
	}
	if tag, ok := tags.EXIF()["Orientation"]; ok {
		if value, ok := asFloat64(tag.Value); ok {
			o := int(value)
			if o >= 1 && o <= 8 {
				orientation = o
			}
		}
	}
	orientation = normalizePhotoOrientation(format, orientation)

	lat, lng, err := tags.GetLatLong()
	if err == nil {
		if _, ok := tags.EXIF()["GPSLatitude"]; ok {
			loc = &OriginalLocation{
				Latitude:  lat,
				Longitude: lng,
			}
			if altTag, ok := tags.EXIF()["GPSAltitude"]; ok {
				if alt, ok := asFloat64(altTag.Value); ok {
					loc.Altitude = &alt
				}
			}
		}
	}

	return takenAt, loc, orientation
}

func normalizePhotoOrientation(format imagemeta.ImageFormat, orientation int) int {
	if format == imagemeta.HEIF {
		// HEIF decoder already applies container orientation; avoid double-rotation.
		return 1
	}
	return orientation
}

func decodeOrientedImage(path string, orientation int) (image.Image, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	src, _, err := image.Decode(f)
	if err != nil {
		return nil, err
	}
	return applyOrientation(src, orientation), nil
}

func rotationQuarterTurns(sideData []struct {
	Rotation *float64 `json:"rotation"`
}, rotateTag string) int {
	for _, side := range sideData {
		if side.Rotation == nil {
			continue
		}
		return rotationToQuarterTurns(*side.Rotation)
	}
	if strings.TrimSpace(rotateTag) == "" {
		return 0
	}
	value, err := strconv.ParseFloat(strings.TrimSpace(rotateTag), 64)
	if err != nil {
		return 0
	}
	return rotationToQuarterTurns(value)
}

func rotationToQuarterTurns(value float64) int {
	deg := int(value)
	deg = ((deg % 360) + 360) % 360
	return deg / 90
}

// imageFormatFromPath maps file extension to imagemeta format constants.
func imageFormatFromPath(path string) (imagemeta.ImageFormat, bool) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".jpg", ".jpeg":
		return imagemeta.JPEG, true
	case ".heic", ".heif":
		return imagemeta.HEIF, true
	case ".png":
		return imagemeta.PNG, true
	default:
		return imagemeta.ImageFormatAuto, false
	}
}

// parseTimestamp normalizes known timestamp formats to UTC RFC3339.
func parseTimestamp(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	layouts := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02 15:04:05",
		"2006:01:02 15:04:05",
	}
	for _, layout := range layouts {
		ts, err := time.Parse(layout, v)
		if err != nil {
			continue
		}
		return ts.UTC().Format(time.RFC3339)
	}
	return ""
}

// asFloat64 coerces metadata values to float64 when possible.
func asFloat64(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int8:
		return float64(n), true
	case int16:
		return float64(n), true
	case int32:
		return float64(n), true
	case int64:
		return float64(n), true
	case uint8:
		return float64(n), true
	case uint16:
		return float64(n), true
	case uint32:
		return float64(n), true
	case uint64:
		return float64(n), true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(n), 64)
		if err != nil {
			return 0, false
		}
		return f, true
	default:
		return 0, false
	}
}

// execCmd is the importer's command leaf. Routing every invocation through it
// keeps verbose stderr mirroring in effect even for wrapped/spied runners.
func (i *importer) execCmd(dir string, name string, args ...string) ([]byte, error) {
	return runCmdTee(i.verboseTeeFor(name, args), dir, name, args...)
}

// verboseTeeFor limits live stderr mirroring to remote git operations. ffmpeg and
// ffprobe run once per file and their banners would drown out import progress.
func (i *importer) verboseTeeFor(name string, args []string) io.Writer {
	if i.verboseOut == nil || name != "git" {
		return nil
	}
	switch gitSubcommand(args) {
	case "push", "fetch", "rebase":
		return i.verboseOut
	}
	return nil
}

// gitSubcommand returns the first non-option token, skipping `-c key=value` pairs.
func gitSubcommand(args []string) string {
	for i := 0; i < len(args); i++ {
		if args[i] == "-c" {
			i++
			continue
		}
		if strings.HasPrefix(args[i], "-") {
			continue
		}
		return args[i]
	}
	return ""
}

// defaultRunCmd executes commands and returns stdout or rich stderr context.
func defaultRunCmd(dir string, name string, args ...string) ([]byte, error) {
	return runCmdTee(nil, dir, name, args...)
}

// runCmdTee executes one command, mirroring child stderr to tee when set so
// long-running work can report progress before it finishes.
func runCmdTee(tee io.Writer, dir string, name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	if tee != nil {
		cmd.Stderr = io.MultiWriter(&stderr, tee)
	} else {
		cmd.Stderr = &stderr
	}
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("%s %s: %s", name, strings.Join(args, " "), msg)
	}
	return stdout.Bytes(), nil
}
