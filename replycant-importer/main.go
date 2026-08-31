package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
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
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/alecthomas/kong"
	"github.com/bep/imagemeta"
	_ "github.com/gen2brain/heic"
	"github.com/google/uuid"
	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/lfsclient"
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
	Verbose     bool   `name:"verbose" short:"v" help:"Mirror git push/fetch/rebase output and LFS upload progress."`
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

// objectUploader uploads encrypted LFS payloads before pointer files are committed.
// Tests inject a fake so unit coverage does not need a live LFS server.
type objectUploader func(ctx context.Context, objects []lfsclient.Object, open lfsclient.OpenFunc) error

// importer dependencies are injectable to make behavior testable end-to-end.
type importer struct {
	stderr io.Writer
	// verboseOut receives live child-process stderr for remote git operations so a
	// multi-minute LFS upload reports progress instead of looking like a hang.
	verboseOut           io.Writer
	log                  func(format string, args ...any) (int, error)
	runCmd               func(ctx context.Context, dir string, name string, args ...string) ([]byte, error)
	newUUID              func() string
	now                  func() time.Time
	extractPhotoMetadata func(path string) (string, *OriginalLocation, int)
	// uploadObjects sends ciphertext to the LFS server; nil means boot constructs one.
	uploadObjects objectUploader
	kek           []byte
	kekEpoch      int
	gitMu         sync.Mutex
	shaMu         sync.Mutex
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

// runCLI parses CLI args and executes the importer with two-stage signal shutdown:
// first interrupt cancels in-flight import work, second cancels the flush push.
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

	workCtx, cancelWork := context.WithCancel(context.Background())
	flushCtx, cancelFlush := context.WithCancel(context.Background())
	defer cancelWork()
	defer cancelFlush()

	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sigCh)
	go func() {
		stage := 0
		for range sigCh {
			stage++
			switch stage {
			case 1:
				fmt.Fprintln(os.Stderr, "cancelling import; press Ctrl+C again to cancel the flush")
				cancelWork()
			case 2:
				cancelFlush()
				signal.Stop(sigCh)
			}
		}
	}()

	imp := &importer{
		stderr:               os.Stderr,
		log:                  fmt.Printf,
		newUUID:              func() string { return uuid.NewString() },
		now:                  time.Now,
		extractPhotoMetadata: extractImageMetadata,
	}
	imp.runCmd = imp.execCmd
	return imp.runStaged(workCtx, flushCtx, cli)
}

// run is the single-context entry point used by tests; both stages share ctx.
func (i *importer) run(ctx context.Context, cli CLI) error {
	return i.runStaged(ctx, ctx, cli)
}

// runStaged validates setup, imports recursively, and keeps processing on
// per-file errors. workCtx cancels prepare/walk; flushCtx cancels commit/push.
func (i *importer) runStaged(workCtx, flushCtx context.Context, cli CLI) error {
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
	if err := i.ensureGitRepo(workCtx, repoAbs); err != nil {
		return err
	}
	if err := i.ensureNoFullLFSClone(workCtx, repoAbs); err != nil {
		return err
	}
	if err := i.ensureCleanWorktree(workCtx, repoAbs); err != nil {
		return err
	}
	if err := i.setupCryptoAndUploader(workCtx, repoAbs); err != nil {
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

	pushCh := make(chan struct{}, 32)
	var pushWG sync.WaitGroup
	if cli.PushEvery > 0 {
		pushWG.Add(1)
		go func() {
			defer pushWG.Done()
			i.pushLoop(workCtx, flushCtx, repoAbs, cli.PushEvery, pushCh)
		}()
	}

	workers := cli.Workers
	if workers <= 0 {
		workers = runtime.NumCPU()
	}
	if workers < 1 {
		workers = 1
	}

	// Unbounded queue so listing never stalls behind slow encrypt/upload work.
	queue := newSourceQueue()
	// Wake workers parked in pop() even if the walker is stuck in ReadDir.
	stopQueueOnCancel := context.AfterFunc(workCtx, queue.close)
	defer stopQueueOnCancel()
	commitCh := make(chan *preparedImport, workers*2)
	progress := &progressTotal{}
	var workerWG sync.WaitGroup
	var commitWG sync.WaitGroup
	var walkWG sync.WaitGroup
	var logMu sync.Mutex
	var walkErr error

	walkWG.Add(1)
	go func() {
		defer walkWG.Done()
		walkErr = streamSourceFiles(workCtx, srcAbs, queue, progress)
		logMu.Lock()
		if walkErr != nil {
			fmt.Fprintf(i.stderr, "error scanning source files: %v\n", walkErr)
		} else if workCtx.Err() == nil {
			_, _ = i.log("boot: found %d source files\n", progress.found.Load())
		}
		logMu.Unlock()
	}()

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
			if err := i.gitCommit(flushCtx, repoAbs, batch); err != nil {
				for _, prepared := range batch {
					if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
						logMu.Lock()
						fmt.Fprintf(i.stderr, "error importing %s: %v\n", prepared.sourceName, err)
						logMu.Unlock()
					}
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
				_, _ = i.log(
					"[%d/%s] %s imported\n",
					prepared.index+1,
					progress.label(),
					prepared.sourceName,
				)
				logMu.Unlock()
				if cli.PushEvery > 0 {
					select {
					case pushCh <- struct{}{}:
					case <-flushCtx.Done():
					}
				}
			}
		}
	}()
	for w := 0; w < workers; w++ {
		workerWG.Add(1)
		go func() {
			defer workerWG.Done()
			for {
				if workCtx.Err() != nil {
					return
				}
				job, ok := queue.pop()
				if !ok {
					return
				}
				if workCtx.Err() != nil {
					return
				}
				prepared, skipped, err := i.prepareFile(workCtx, repoAbs, cli.DeviceSpace, job.path, knownSHAs, knownPathSizes)
				if err != nil {
					if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
						logMu.Lock()
						fmt.Fprintf(i.stderr, "error importing %s: %v\n", job.path, err)
						logMu.Unlock()
					}
					continue
				}
				if skipped {
					logMu.Lock()
					_, _ = i.log(
						"[%d/%s] %s (duplicate, skipped)\n",
						job.index+1,
						progress.label(),
						filepath.Base(job.path),
					)
					logMu.Unlock()
					continue
				}
				if prepared == nil {
					continue
				}
				prepared.index = job.index
				select {
				case commitCh <- prepared:
				case <-flushCtx.Done():
					if prepared.reservedSHA != "" {
						i.shaMu.Lock()
						delete(knownSHAs, prepared.reservedSHA)
						i.shaMu.Unlock()
					}
					for _, p := range prepared.writtenPaths {
						_ = os.Remove(p)
					}
					return
				}
			}
		}()
	}
	walkWG.Wait()
	workerWG.Wait()
	close(commitCh)
	commitWG.Wait()

	close(pushCh)
	pushWG.Wait()
	// Flush remaining commits (and recover from a late push rejection) so a finished
	// import does not leave work local-only when periodic push is enabled.
	if cli.PushEvery > 0 {
		if workCtx.Err() != nil {
			_, _ = i.log(
				"cancelled: pushing %s pending commit(s); press Ctrl+C again to cancel immediately\n",
				i.pendingCommitLabel(flushCtx, repoAbs),
			)
		}
		i.gitMu.Lock()
		err := i.pushWithRebase(flushCtx, repoAbs)
		i.gitMu.Unlock()
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || flushCtx.Err() != nil {
				fmt.Fprintf(
					i.stderr,
					"push cancelled: %s commit(s) remain local; run git push in the repo\n",
					i.pendingCommitLabel(context.Background(), repoAbs),
				)
				return nil
			}
			return fmt.Errorf("final push failed: %w", err)
		}
	}
	if walkErr != nil {
		return walkErr
	}
	return nil
}

// ensureGitRepo validates the repo arg points at an existing git worktree.
func (i *importer) ensureGitRepo(ctx context.Context, repoPath string) error {
	out, err := i.runCmd(ctx, repoPath, "git", "rev-parse", "--is-inside-work-tree")
	if err != nil {
		return fmt.Errorf("repo path is not a git repository: %w", err)
	}
	if strings.TrimSpace(string(out)) != "true" {
		return fmt.Errorf("repo path is not a git worktree")
	}
	return nil
}

// ensureCleanWorktree refuses to start (or rebase) when tracked files diverge
// from the index. A staged-but-deleted worktree permanently blocks rebase with
// an opaque git error; naming the paths and the recovery command is actionable.
func (i *importer) ensureCleanWorktree(ctx context.Context, repoPath string) error {
	out, err := i.runCmd(ctx, repoPath, "git", "status", "--porcelain", "--untracked-files=no")
	if err != nil {
		return fmt.Errorf("check worktree cleanliness: %w", err)
	}
	lines := make([]string, 0)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		lines = append(lines, line)
	}
	if len(lines) == 0 {
		return nil
	}
	const maxShow = 10
	shown := lines
	if len(shown) > maxShow {
		shown = shown[:maxShow]
	}
	var b strings.Builder
	fmt.Fprintf(&b, "repository worktree is dirty (%d tracked path(s) differ from the index):\n", len(lines))
	for _, line := range shown {
		fmt.Fprintf(&b, "  %s\n", line)
	}
	if len(lines) > maxShow {
		fmt.Fprintf(&b, "  ... and %d more\n", len(lines)-maxShow)
	}
	fmt.Fprintf(&b, "restore tracked files with: git -C %s checkout -- .", repoPath)
	return errors.New(b.String())
}

// ensureNoFullLFSClone rejects filter-driven clones so the importer can write
// pointers itself without git-lfs clean rewriting multi-megabyte binaries.
func (i *importer) ensureNoFullLFSClone(ctx context.Context, repoPath string) error {
	out, err := i.runCmd(ctx, repoPath, "git", "rev-parse", "--git-dir")
	if err != nil {
		return fmt.Errorf("failed to resolve git dir: %w", err)
	}
	gitDir := strings.TrimSpace(string(out))
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(repoPath, gitDir)
	}
	attrPath := filepath.Join(gitDir, "info", "attributes")
	if raw, readErr := os.ReadFile(attrPath); readErr == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			trimmed := strings.TrimSpace(line)
			if trimmed == "binary/** filter=replycant-crypt" {
				return fmt.Errorf("repository has binary/** LFS filters configured; re-clone with git-replycant clone --no-lfs")
			}
		}
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return fmt.Errorf("failed reading %s: %w", attrPath, readErr)
	}
	if _, err := i.runCmd(ctx, repoPath, "git", "config", "--local", "--get", "lfs.url"); err == nil {
		return fmt.Errorf("repository has lfs.url configured; re-clone with git-replycant clone --no-lfs")
	}
	return nil
}

// setupCryptoAndUploader loads repository encryption material and the LFS uploader
// so every binary can be encrypted and pushed before its pointer is committed.
func (i *importer) setupCryptoAndUploader(ctx context.Context, repoPath string) error {
	local, err := gitcrypt.LoadLocalIdentity(repoPath)
	if err != nil {
		return fmt.Errorf("load repository identity: %w", err)
	}
	if err := gitcrypt.RequireSupportedDatabaseVersionInWorktree(repoPath); err != nil {
		return err
	}
	epochRaw, err := os.ReadFile(filepath.Join(repoPath, "encryption", "current"))
	if err != nil {
		return fmt.Errorf("read encryption/current: %w", err)
	}
	epoch, err := gitcrypt.ParseCurrentEpoch(epochRaw)
	if err != nil {
		return err
	}
	envelopePath := filepath.Join(repoPath, "encryption", "epochs", fmt.Sprintf("%d.age", epoch))
	envelope, err := os.ReadFile(envelopePath)
	if err != nil {
		return fmt.Errorf("read %s: %w", envelopePath, err)
	}
	kek, err := gitcrypt.UnwrapKEKFromAgeEnvelope(envelope, local.Identity.AgePrivateKeyBase64)
	if err != nil {
		return fmt.Errorf("unwrap KEK for epoch %d: %w", epoch, err)
	}
	i.kek = kek
	i.kekEpoch = epoch

	if i.uploadObjects != nil {
		return nil
	}

	originURL, err := i.runCmd(ctx, repoPath, "git", "config", "--get", "remote.origin.url")
	if err != nil {
		return fmt.Errorf("resolve remote.origin.url: %w", err)
	}
	lfsURL, err := lfsclient.DeriveEndpointURL(strings.TrimSpace(string(originURL)))
	if err != nil {
		return fmt.Errorf("derive LFS URL: %w", err)
	}
	endpoint, err := lfsclient.ParseEndpoint(lfsURL)
	if err != nil {
		return fmt.Errorf("parse LFS URL: %w", err)
	}
	caPath, err := i.gitConfigValue(ctx, repoPath, "http.sslCAInfo")
	if err != nil {
		return err
	}
	certPath, err := i.gitConfigValue(ctx, repoPath, "http.sslCert")
	if err != nil {
		return err
	}
	keyPath, err := i.gitConfigValue(ctx, repoPath, "http.sslKey")
	if err != nil {
		return err
	}
	httpClient, err := lfsclient.NewMTLSHTTPClient(caPath, certPath, keyPath)
	if err != nil {
		return err
	}
	var logOut io.Writer
	if i.verboseOut != nil {
		logOut = i.verboseOut
	}
	client := &lfsclient.Client{
		HTTP:     httpClient,
		Endpoint: endpoint,
		Log:      logOut,
	}
	i.uploadObjects = func(ctx context.Context, objects []lfsclient.Object, open lfsclient.OpenFunc) error {
		return client.Upload(ctx, "", objects, open)
	}
	return nil
}

// gitConfigValue reads one local git config key required for mTLS LFS uploads.
func (i *importer) gitConfigValue(ctx context.Context, repoPath, key string) (string, error) {
	out, err := i.runCmd(ctx, repoPath, "git", "config", "--local", "--get", key)
	if err != nil {
		return "", fmt.Errorf("failed to read git config %q: %w", key, err)
	}
	value := strings.TrimSpace(string(out))
	if value == "" {
		return "", fmt.Errorf("missing git config %q", key)
	}
	return value, nil
}

// ensureTool fails fast when external tool dependencies are missing from PATH.
func (i *importer) ensureTool(name string) error {
	if _, err := exec.LookPath(name); err != nil {
		return fmt.Errorf("%s not found in PATH", name)
	}
	return nil
}

// sourceFile is one media path discovered while scanning, with a stable 0-based
// index used only for progress reporting.
type sourceFile struct {
	index int
	path  string
}

// sourceQueue hands scanned files to import workers without backpressure. A
// bounded channel stalls the walk behind slow encrypt/upload work, which keeps
// the file total unknown for nearly all of a large import.
type sourceQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	items  []sourceFile
	closed bool
}

func newSourceQueue() *sourceQueue {
	q := &sourceQueue{}
	q.cond = sync.NewCond(&q.mu)
	return q
}

func (q *sourceQueue) push(job sourceFile) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	q.items = append(q.items, job)
	q.cond.Signal()
}

func (q *sourceQueue) close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.closed = true
	q.cond.Broadcast()
}

// pop blocks until an item is available or the queue is closed and drained.
func (q *sourceQueue) pop() (sourceFile, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.items) == 0 && !q.closed {
		q.cond.Wait()
	}
	if len(q.items) == 0 {
		return sourceFile{}, false
	}
	job := q.items[0]
	q.items[0] = sourceFile{}
	q.items = q.items[1:]
	return job, true
}

// progressTotal tracks how many media files the walker has found so progress
// lines can show a running count until the walk completes.
type progressTotal struct {
	found atomic.Int64
	done  atomic.Bool
}

// label renders the progress denominator; listing runs concurrently with
// importing, so the total is unknown until the walk completes.
func (p *progressTotal) label() string {
	if !p.done.Load() {
		return fmt.Sprintf("(calculating, %d found)", p.found.Load())
	}
	return strconv.FormatInt(p.found.Load(), 10)
}

func (p *progressTotal) finish() {
	p.done.Store(true)
}

// streamSourceFiles walks root and streams supported media paths to q so
// workers can encrypt/upload before the full tree is listed. It owns and closes
// q, and marks progress done when the walk finishes or is cancelled.
func streamSourceFiles(ctx context.Context, root string, q *sourceQueue, progress *progressTotal) error {
	defer q.close()
	defer progress.finish()

	index := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if ctx.Err() != nil {
			return fs.SkipAll
		}
		if d.IsDir() {
			return nil
		}
		if mediaTypeFromPath(path) == "" {
			return nil
		}
		index++
		progress.found.Store(int64(index))
		q.push(sourceFile{index: index - 1, path: path})
		return nil
	})
	if err != nil && !errors.Is(err, fs.SkipAll) {
		return err
	}
	return nil
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
func (i *importer) prepareFile(ctx context.Context, repoPath, deviceSpace, sourcePath string, knownSHAs map[string]struct{}, knownPathSizes map[string]int64) (result *preparedImport, skipped bool, retErr error) {
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
	if err := ctx.Err(); err != nil {
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

	meta, err := i.probeMedia(ctx, sourcePath, mediaType)
	if err != nil {
		return nil, false, err
	}

	name := strings.ToLower(i.newUUID())
	originalRef := fmt.Sprintf("%s/%s/Original/%s", deviceSpace, apiVersion, name)
	manifestPath := filepath.Join(repoPath, "manifests", deviceSpace, apiVersion, "Original", shardName(name)+".yaml")
	binaryPath := filepath.Join(repoPath, "binary", deviceSpace, apiVersion, "Original", shardName(name))

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

	thumbs, err := i.generateThumbnails(ctx, deviceSpace, name, sourcePath, mediaType, meta.duration, originalRef, photoSrc)
	if err != nil {
		return nil, false, err
	}
	thumbs.manifestPath = filepath.Join(
		repoPath,
		"manifests",
		deviceSpace,
		apiVersion,
		"ThumbnailSet",
		shardName(thumbs.manifest.Metadata.Name)+".yaml",
	)
	if err := writeYAMLFile(thumbs.manifestPath, thumbs.manifest); err != nil {
		return nil, false, err
	}
	writtenPaths = append(writtenPaths, thumbs.manifestPath)

	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	uploads := make([]pendingLFSUpload, 0, 1+len(thumbs.payloads))
	originalUpload, err := i.prepareOriginalUpload(sourcePath, binaryPath, size)
	if err != nil {
		return nil, false, err
	}
	uploads = append(uploads, originalUpload)
	for _, payload := range thumbs.payloads {
		thumbBinaryPath := filepath.Join(repoPath, "binary", deviceSpace, apiVersion, "ThumbnailSet", shardName(payload.name))
		thumbUpload, err := i.prepareBytesUpload(payload.jpeg, thumbBinaryPath)
		if err != nil {
			return nil, false, err
		}
		uploads = append(uploads, thumbUpload)
	}
	if err := i.uploadAndWritePointers(ctx, uploads); err != nil {
		return nil, false, err
	}
	for _, upload := range uploads {
		writtenPaths = append(writtenPaths, upload.pointerPath)
	}

	return &preparedImport{
		sourceName:   filepath.Base(sourcePath),
		writtenPaths: writtenPaths,
		reservedSHA:  reservedSHA,
	}, false, nil
}

// pendingLFSUpload holds one encrypted object ready for batch upload and pointer write.
type pendingLFSUpload struct {
	pointerPath string
	oid         string
	size        int64
	wrappedDEK  string
	open        func() (io.ReadCloser, error)
}

type generatedThumbnails struct {
	manifestPath string
	manifest     ThumbnailSetManifest
	payloads     []thumbnailPayload
}

type thumbnailPayload struct {
	name string
	jpeg []byte
}

// generateThumbnails creates all variants in memory so import never stages
// plaintext thumbnails in the worktree or TMPDIR.
func (i *importer) generateThumbnails(ctx context.Context, deviceSpace, originalName, sourcePath, mediaType string, duration *float64, originalRef string, photoSrc image.Image) (generatedThumbnails, error) {
	specs := []thumbSpec{
		{suffix: "150x150", size: 150, square: true, scaler: xdraw.ApproxBiLinear},
		{suffix: "225x225", size: 225, square: true, scaler: xdraw.ApproxBiLinear},
		{suffix: "1024", size: 1024, square: false, scaler: xdraw.CatmullRom},
	}
	out := generatedThumbnails{
		payloads: make([]thumbnailPayload, 0, len(specs)),
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
	for _, s := range specs {
		thumbName := fmt.Sprintf("%s-thumb-%s", originalName, s.suffix)
		var jpegBytes []byte
		var thumbW, thumbH int
		var err error
		if mediaType == "photo" {
			jpegBytes, thumbW, thumbH, err = scalePhotoThumbnail(photoSrc, s)
		} else {
			jpegBytes, err = i.makeThumbnailJPEG(ctx, sourcePath, mediaType, duration, s)
			if err == nil {
				thumbW, thumbH, err = jpegDimensions(jpegBytes)
			}
		}
		if err != nil {
			return generatedThumbnails{}, err
		}
		sum := sha256.Sum256(jpegBytes)
		out.payloads = append(out.payloads, thumbnailPayload{name: thumbName, jpeg: jpegBytes})
		out.manifest.Spec.Thumbnails = append(out.manifest.Spec.Thumbnails, ThumbnailEntry{
			Name:     thumbName,
			SHA256:   hex.EncodeToString(sum[:]),
			Width:    thumbW,
			Height:   thumbH,
			Filesize: int64(len(jpegBytes)),
		})
	}
	return out, nil
}

// makeThumbnailJPEG renders one thumbnail variant to JPEG bytes via ffmpeg stdout.
func (i *importer) makeThumbnailJPEG(ctx context.Context, inputPath, mediaType string, duration *float64, spec thumbSpec) ([]byte, error) {
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
	args = append(args, "-vf", filter, "-frames:v", "1", "-q:v", "2")
	if mediaType == "video" {
		args = append(args, "-pix_fmt", "yuvj420p")
	}
	args = append(args, "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1")
	out, err := i.runCmd(ctx, "", "ffmpeg", args...)
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("ffmpeg produced empty thumbnail")
	}
	return out, nil
}

// scalePhotoThumbnail encodes one photo thumbnail into memory.
func scalePhotoThumbnail(src image.Image, spec thumbSpec) ([]byte, int, int, error) {
	srcBounds := src.Bounds()
	if srcBounds.Dx() == 0 || srcBounds.Dy() == 0 {
		return nil, 0, 0, fmt.Errorf("invalid image dimensions")
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

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 85}); err != nil {
		return nil, 0, 0, err
	}
	return buf.Bytes(), dstW, dstH, nil
}

// jpegDimensions reads width/height from in-memory JPEG bytes without a second ffprobe.
func jpegDimensions(jpegBytes []byte) (int, int, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(jpegBytes))
	if err != nil {
		return 0, 0, err
	}
	if cfg.Width <= 0 || cfg.Height <= 0 {
		return 0, 0, fmt.Errorf("invalid thumbnail dimensions")
	}
	return cfg.Width, cfg.Height, nil
}

// prepareOriginalUpload encrypts the source once to learn the oid, then re-encrypts
// on open for the upload body so large videos never sit fully in RAM.
func (i *importer) prepareOriginalUpload(sourcePath, pointerPath string, plaintextSize int64) (pendingLFSUpload, error) {
	dek, err := gitcrypt.NewDEK()
	if err != nil {
		return pendingLFSUpload{}, err
	}
	wrappedDEK, err := gitcrypt.WrapDEK(i.kek, dek, i.kekEpoch)
	if err != nil {
		return pendingLFSUpload{}, err
	}
	oid, size, err := hashEncryptedFile(sourcePath, plaintextSize, dek)
	if err != nil {
		return pendingLFSUpload{}, err
	}
	return pendingLFSUpload{
		pointerPath: pointerPath,
		oid:         oid,
		size:        size,
		wrappedDEK:  wrappedDEK,
		open: func() (io.ReadCloser, error) {
			f, err := os.Open(sourcePath)
			if err != nil {
				return nil, err
			}
			reader, err := gitcrypt.NewChunkedEncryptReader(f, plaintextSize, dek)
			if err != nil {
				_ = f.Close()
				return nil, err
			}
			return &encryptReadCloser{Reader: reader, closer: f}, nil
		},
	}, nil
}

// prepareBytesUpload encrypts small in-memory payloads once and reuses the
// ciphertext for both hashing and upload.
func (i *importer) prepareBytesUpload(plaintext []byte, pointerPath string) (pendingLFSUpload, error) {
	dek, err := gitcrypt.NewDEK()
	if err != nil {
		return pendingLFSUpload{}, err
	}
	wrappedDEK, err := gitcrypt.WrapDEK(i.kek, dek, i.kekEpoch)
	if err != nil {
		return pendingLFSUpload{}, err
	}
	ciphertext, err := gitcrypt.EncryptChunked(plaintext, dek)
	if err != nil {
		return pendingLFSUpload{}, err
	}
	sum := sha256.Sum256(ciphertext)
	return pendingLFSUpload{
		pointerPath: pointerPath,
		oid:         hex.EncodeToString(sum[:]),
		size:        int64(len(ciphertext)),
		wrappedDEK:  wrappedDEK,
		open: func() (io.ReadCloser, error) {
			return io.NopCloser(bytes.NewReader(ciphertext)), nil
		},
	}, nil
}

// uploadAndWritePointers pushes ciphertext first so lfs-prereceive always finds
// objects, then writes pointer files into the worktree for the upcoming commit.
func (i *importer) uploadAndWritePointers(ctx context.Context, uploads []pendingLFSUpload) error {
	if i.uploadObjects == nil {
		return fmt.Errorf("LFS uploader is not configured")
	}
	objects := make([]lfsclient.Object, len(uploads))
	byOID := make(map[string]pendingLFSUpload, len(uploads))
	for idx, upload := range uploads {
		objects[idx] = lfsclient.Object{OID: upload.oid, Size: upload.size}
		byOID[upload.oid] = upload
	}
	open := func(object lfsclient.Object) (io.ReadCloser, error) {
		upload, ok := byOID[object.OID]
		if !ok {
			return nil, fmt.Errorf("unknown LFS object %s", object.OID)
		}
		return upload.open()
	}
	if err := i.uploadObjects(ctx, objects, open); err != nil {
		return fmt.Errorf("upload LFS objects: %w", err)
	}
	for _, upload := range uploads {
		pointer := gitcrypt.BuildLFSPointer(upload.oid, upload.size)
		withHeaders, err := gitcrypt.AppendReplycantHeaders(pointer, i.kekEpoch, upload.wrappedDEK)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(upload.pointerPath), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(upload.pointerPath, withHeaders, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// hashEncryptedFile streams ciphertext through SHA-256 without retaining it.
func hashEncryptedFile(path string, plaintextSize int64, dek []byte) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	reader, err := gitcrypt.NewChunkedEncryptReader(f, plaintextSize, dek)
	if err != nil {
		return "", 0, err
	}
	h := sha256.New()
	n, err := io.Copy(h, reader)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// encryptReadCloser closes the underlying plaintext file when the encrypting
// upload body is finished or abandoned.
type encryptReadCloser struct {
	io.Reader
	closer io.Closer
}

func (r *encryptReadCloser) Close() error {
	return r.closer.Close()
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
func (i *importer) probeMedia(ctx context.Context, path string, mediaType string) (mediaMeta, error) {
	args := []string{
		"-v", "error",
		"-print_format", "json",
		"-show_streams",
		"-show_format",
		path,
	}
	out, err := i.runCmd(ctx, "", "ffprobe", args...)
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
// On commit failure it unstages the batch so the caller's worktree cleanup
// cannot leave staged-but-deleted index entries that permanently block rebase.
func (i *importer) gitCommit(ctx context.Context, repoPath string, batch []*preparedImport) error {
	if len(batch) == 0 {
		return nil
	}
	i.gitMu.Lock()
	defer i.gitMu.Unlock()

	addArgs := []string{"add"}
	seen := map[string]struct{}{}
	var relPaths []string
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
			relPaths = append(relPaths, rel)
			addArgs = append(addArgs, rel)
		}
	}
	if len(addArgs) == 1 {
		return fmt.Errorf("git add failed: no paths to add")
	}
	if _, err := i.runCmd(ctx, repoPath, "git", addArgs...); err != nil {
		return fmt.Errorf("git add failed: %w", err)
	}
	msg := fmt.Sprintf("import: %s", strings.Join(sourceNames, ", "))
	commitArgs := []string{
		"-c", "user.name=Replycant Importer",
		"-c", "user.email=importer@replycant.com",
		"commit", "-m", msg, "--author", "Replycant Importer <importer@replycant.com>",
	}
	if _, err := i.runCmd(ctx, repoPath, "git", commitArgs...); err != nil {
		return i.recoverFailedCommit(repoPath, relPaths, err)
	}
	return nil
}

// recoverFailedCommit unstages the batch after a commit error. If the commit
// actually landed (killed after the ref update), treat it as success so the
// caller does not delete committed files from the worktree.
func (i *importer) recoverFailedCommit(repoPath string, relPaths []string, commitErr error) error {
	bg := context.Background()
	resetArgs := append([]string{"reset", "-q", "--"}, relPaths...)
	if _, resetErr := i.runCmd(bg, repoPath, "git", resetArgs...); resetErr != nil {
		return fmt.Errorf("git commit failed: %w (also failed to unstage: %v)", commitErr, resetErr)
	}
	if len(relPaths) == 0 {
		return fmt.Errorf("git commit failed: %w", commitErr)
	}
	if _, err := i.runCmd(bg, repoPath, "git", "cat-file", "-e", "HEAD:"+relPaths[0]); err == nil {
		return nil
	}
	return fmt.Errorf("git commit failed: %w", commitErr)
}

// pushLoop periodically runs git push based on successful commit notifications.
// After workCtx is cancelled it drains tokens without starting new pushes; the
// final flush covers the backlog. flushCtx aborts an in-flight push immediately.
func (i *importer) pushLoop(workCtx, flushCtx context.Context, repoPath string, every int, ch <-chan struct{}) {
	if every <= 0 {
		return
	}
	count := 0
	for {
		select {
		case <-flushCtx.Done():
			return
		case _, ok := <-ch:
			if !ok {
				return
			}
			if workCtx.Err() != nil {
				continue
			}
			count++
			if count < every {
				continue
			}
			count = 0
			i.gitMu.Lock()
			err := i.pushWithRebase(flushCtx, repoPath)
			i.gitMu.Unlock()
			if err != nil {
				if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
					return
				}
				fmt.Fprintf(i.stderr, "error pushing repository: %v\n", err)
			}
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
func (i *importer) pushWithRebase(ctx context.Context, repoPath string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	start := i.now()
	_, _ = i.log("push: start pending_commits=%s\n", i.pendingCommitLabel(ctx, repoPath))
	var lastPushErr error
	for attempt := 1; attempt <= pushRebaseMaxAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		_, err := i.runCmd(ctx, repoPath, "git", "push")
		if err == nil {
			_, _ = i.log("push: done attempts=%d elapsed=%s\n", attempt, i.now().Sub(start).Round(time.Millisecond))
			return nil
		}
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return err
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

		branchOut, branchErr := i.runCmd(ctx, repoPath, "git", "rev-parse", "--abbrev-ref", "HEAD")
		if branchErr != nil {
			return lastPushErr
		}
		branch := strings.TrimSpace(string(branchOut))
		if branch == "" || branch == "HEAD" {
			return lastPushErr
		}
		// Fetch failure usually means the original push failed for network reasons,
		// not a non-fast-forward rejection — skip rebase and surface the push error.
		if _, fetchErr := i.runCmd(ctx, repoPath, "git", "fetch", "origin"); fetchErr != nil {
			return lastPushErr
		}
		// Surface dirty-worktree paths before rebase so the failure is actionable
		// instead of git's opaque "cannot rebase: You have unstaged changes".
		if err := i.ensureCleanWorktree(ctx, repoPath); err != nil {
			return err
		}
		rebaseArgs := []string{
			"-c", "user.name=Replycant Importer",
			"-c", "user.email=importer@replycant.com",
			"-c", "rebase.backend=merge",
			"rebase", "--no-autostash", "origin/" + branch,
		}
		if _, rebaseErr := i.runCmd(ctx, repoPath, "git", rebaseArgs...); rebaseErr != nil {
			_, _ = i.runCmd(context.Background(), repoPath, "git", "rebase", "--abort")
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
func (i *importer) pendingCommitLabel(ctx context.Context, repoPath string) string {
	out, err := i.runCmd(ctx, repoPath, "git", "rev-list", "--count", "@{upstream}..HEAD")
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
func (i *importer) execCmd(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
	return runCmdTee(i.verboseTeeFor(name, args), ctx, dir, name, args...)
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
func defaultRunCmd(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
	return runCmdTee(nil, ctx, dir, name, args...)
}

// runCmdTee executes one command under ctx so cancellation kills children.
// Children run in their own process group so a terminal Ctrl+C delivered to the
// importer's foreground group cannot kill an in-flight git commit that still
// belongs to the flush stage. Child stderr is mirrored to tee when set.
func runCmdTee(tee io.Writer, ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	// Bound Wait after Kill so a grandchild holding stdout cannot stall exit.
	cmd.WaitDelay = 2 * time.Second
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		// Negative pid kills the whole process group started above.
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
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
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), ctxErr)
		}
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("%s %s: %s", name, strings.Join(args, " "), msg)
	}
	return stdout.Bytes(), nil
}
