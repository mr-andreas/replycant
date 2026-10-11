package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/lfsclient"
	"github.com/mr-andreas/replycant/pkg/pairing"
	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
	"github.com/mr-andreas/replycant/pkg/tailnetagent"
	"github.com/skip2/go-qrcode"
)

const (
	// authPollInterval controls how frequently clone onboarding retries repository auth checks.
	authPollInterval = 3 * time.Second
	// discoveryPollInterval matches the desktop app: approval is a person
	// scanning a QR code, so polling faster does not finish pairing sooner.
	discoveryPollInterval = 2 * time.Second
	// pairingTimeout matches the discovery record TTL. Waiting longer can
	// only observe a slot the server has already deleted.
	pairingTimeout = 10 * time.Minute

	defaultDiscoveryURL   = "https://discovery.replycant.com"
	defaultQRAddr         = "127.0.0.1:0"
	defaultCloneDirectory = "replycant"
)

// CloneOptions captures CLI inputs required for tailnet pairing and clone setup.
type CloneOptions struct {
	DeviceName   string
	Depth        int
	Bare         bool
	NoLFS        bool
	DiscoveryURL string
	QRAddr       string
	Directory    string
}

// cloneRuntime replaces the parts of pairing that need a network or a live
// tailnet node, so tests can seal a record and stop before git fetch.
type cloneRuntime struct {
	pollInterval time.Duration
	httpClient   *http.Client
	newSecret    func() (pairing.Secret, error)
	join         func(context.Context, string, tailnetagent.StartConfig) error
	finish       func(context.Context, cloneFinish) error
}

// cloneFinish is the repository state after the tailnet node is up and the
// CA has been written. The real finish fetches and checks out.
type cloneFinish struct {
	RepoDir string
	RepoURL string
	Local   gitcrypt.LocalIdentity
	CAFile  string
	LFSURL  string
	Depth   int
	Bare    bool
}

// RunCloneCommand pairs this machine into the deployment tailnet and clones
// gitd over it. There is no direct-connection alternative.
func RunCloneCommand(options CloneOptions) error {
	return runClone(options, cloneRuntime{})
}

func runClone(options CloneOptions, runtime cloneRuntime) error {
	options, err := NormalizeCloneOptions(options)
	if err != nil {
		return err
	}
	if err := requireRemoteHelper(); err != nil {
		return err
	}
	repoURL := remoteHelperPrefix + tailnetaddr.GitdURL()
	gitURL := tailnetaddr.GitdURL()
	lfsURL, err := DeriveLFSURL(gitURL)
	if err != nil {
		return err
	}
	if options.NoLFS {
		lfsURL = ""
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	pairCtx, cancelPair := context.WithTimeout(ctx, pairingTimeout)
	defer cancelPair()

	repoDir, err := InitializeRepository(ctx, options.Directory, repoURL, options.Bare)
	if err != nil {
		return err
	}
	local, created, err := gitcrypt.EnsureLocalIdentity(repoDir, options.DeviceName)
	if err != nil {
		return err
	}
	if created {
		fmt.Fprintf(os.Stderr, "Generated new local identity in %s\n", local.ConfigDirectory)
	}

	newSecret := runtime.newSecret
	if newSecret == nil {
		newSecret = pairing.NewSecret
	}
	secret, err := newSecret()
	if err != nil {
		return err
	}
	qrPayload, err := gitcrypt.BuildPublicKeyQrPayload(local.Identity, secret.String())
	if err != nil {
		return err
	}
	server, baseURL, err := StartQRServer(qrPayload, options.QRAddr)
	if err != nil {
		return err
	}
	defer server.Close()
	fmt.Fprintf(os.Stderr, "Open %s to view the pairing QR code.\n", baseURL)
	fmt.Fprintln(os.Stderr, "Waiting for a paired device to approve this one...")

	interval := runtime.pollInterval
	if interval <= 0 {
		interval = discoveryPollInterval
	}
	sealed, err := PollPairingRecord(pairCtx, options.DiscoveryURL, secret.Slot(), runtime.httpClient, interval)
	if err != nil {
		return err
	}
	payload, err := pairing.Open(secret, sealed)
	if err != nil {
		return err
	}

	caFilePath, err := WriteCAToRepoReplycantDir(payload.CAPEM, local.ConfigDirectory)
	if err != nil {
		return err
	}
	gitDir, err := resolveGitDir(repoDir)
	if err != nil {
		return err
	}
	startCfg, persisted, err := tailnetStartConfig(gitDir, local, caFilePath, payload)
	if err != nil {
		return err
	}
	join := runtime.join
	if join == nil {
		join = joinTailnet
	}
	if err := join(ctx, gitDir, startCfg); err != nil {
		return err
	}
	// Persisted only after the node is up, so a failed join leaves nothing
	// for the next git command to treat as a trusted deployment.
	if err := tailnetagent.SaveConfig(gitDir, persisted); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Joined the tailnet. Waiting for repository authorization...")

	finish := runtime.finish
	if finish == nil {
		finish = finishClone
	}
	if err := finish(ctx, cloneFinish{
		RepoDir: repoDir,
		RepoURL: repoURL,
		Local:   local,
		CAFile:  caFilePath,
		LFSURL:  lfsURL,
		Depth:   options.Depth,
		Bare:    options.Bare,
	}); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Clone complete and filters configured in %s\n", repoDir)
	return nil
}

// finishClone fetches and checks out once the device is on the tailnet and
// an already-paired device has committed its key.
func finishClone(ctx context.Context, finish cloneFinish) error {
	if err := PollAuthorization(ctx, finish.RepoDir, finish.RepoURL, finish.Local, finish.CAFile); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Authorization confirmed. Proceeding with clone.")
	if err := FetchRepository(ctx, finish.RepoDir, finish.Local, finish.CAFile, finish.Depth); err != nil {
		return err
	}
	defaultBranch, err := ResolveDefaultRemoteBranch(finish.RepoDir)
	if err != nil {
		return err
	}
	if err := RequireSupportedDatabaseVersionAtRef(ctx, finish.RepoDir, "origin/"+defaultBranch); err != nil {
		return err
	}
	if err := ConfigureRepository(finish.RepoDir, finish.LFSURL, finish.Local, finish.CAFile); err != nil {
		return err
	}
	if finish.Bare {
		return nil
	}
	if err := PreExtractEncryptionFiles(ctx, finish.RepoDir, defaultBranch); err != nil {
		return err
	}
	return CheckoutTrackingBranch(ctx, finish.RepoDir, defaultBranch)
}

// requireRemoteHelper fails before pairing when git would be unable to reach
// gitd. The helper is the same binary, installed under the name git looks up.
func requireRemoteHelper() error {
	if _, err := exec.LookPath(remoteHelperName); err != nil {
		return fmt.Errorf("%s is not on PATH; symlink it to the git-replycant binary", remoteHelperName)
	}
	return nil
}

// tailnetStartConfig builds the agent stdin payload from the opened pairing
// record and the identity just written into the repository.
func tailnetStartConfig(gitDir string, local gitcrypt.LocalIdentity, caFilePath string, payload pairing.Payload) (tailnetagent.StartConfig, tailnetagent.PersistedConfig, error) {
	addr, serverName, err := headscaleDial(payload.HeadscaleURL)
	if err != nil {
		return tailnetagent.StartConfig{}, tailnetagent.PersistedConfig{}, err
	}
	caPEM, err := os.ReadFile(caFilePath)
	if err != nil {
		return tailnetagent.StartConfig{}, tailnetagent.PersistedConfig{}, fmt.Errorf("read repository CA: %w", err)
	}
	certPEM, err := os.ReadFile(local.ClientCertPath)
	if err != nil {
		return tailnetagent.StartConfig{}, tailnetagent.PersistedConfig{}, fmt.Errorf("read device certificate: %w", err)
	}
	keyPEM, err := os.ReadFile(local.ClientKeyPath)
	if err != nil {
		return tailnetagent.StartConfig{}, tailnetagent.PersistedConfig{}, fmt.Errorf("read device key: %w", err)
	}
	persisted := tailnetagent.PersistedConfig{
		HeadscaleAddr:       addr,
		HeadscaleServerName: serverName,
		Hostname:            local.Identity.DeviceName,
	}
	return tailnetagent.StartConfig{
		GitDir:              gitDir,
		HeadscaleAddr:       addr,
		HeadscaleServerName: serverName,
		CAPEM:               string(caPEM),
		ClientCertPEM:       string(certPEM),
		ClientKeyPEM:        string(keyPEM),
		Hostname:            local.Identity.DeviceName,
	}, persisted, nil
}

// headscaleDial turns the URL from the pairing record into the host:port the
// shim dials. The URL form is how headscale advertises itself.
func headscaleDial(headscaleURL string) (string, string, error) {
	parsed, err := url.Parse(strings.TrimSpace(headscaleURL))
	if err != nil {
		return "", "", fmt.Errorf("headscale URL is not a valid URL: %w", err)
	}
	host := parsed.Hostname()
	if host == "" {
		return "", "", fmt.Errorf("headscale URL has no hostname: %q", headscaleURL)
	}
	port := parsed.Port()
	if port == "" {
		if parsed.Scheme == "http" {
			port = "80"
		} else {
			port = "443"
		}
	}
	return net.JoinHostPort(host, port), host, nil
}

// joinTailnet starts the per-repo agent, which mints its own tailnet key
// because the authorizing device committed this device's key before it
// published the pairing record. Later git commands start it the same way.
func joinTailnet(ctx context.Context, gitDir string, cfg tailnetagent.StartConfig) error {
	_, err := tailnetagent.Ensure(ctx, gitDir, cfg, nil)
	return err
}

// WriteCAToRepoReplycantDir stores discovered CA trust material per repository for stable git TLS setup.
func WriteCAToRepoReplycantDir(caPEM string, replycantDir string) (string, error) {
	if err := os.MkdirAll(replycantDir, 0o755); err != nil {
		return "", fmt.Errorf("failed to create replycant directory: %w", err)
	}
	destPath := filepath.Join(replycantDir, "ca.pem")
	if err := os.WriteFile(destPath, []byte(caPEM), 0o600); err != nil {
		return "", fmt.Errorf("failed to write repo-local CA file %s: %w", destPath, err)
	}
	return destPath, nil
}

// NormalizeCloneOptions validates clone inputs before any repository is created.
func NormalizeCloneOptions(options CloneOptions) (CloneOptions, error) {
	options.DeviceName = strings.TrimSpace(options.DeviceName)
	options.Directory = strings.TrimSpace(options.Directory)
	options.DiscoveryURL = strings.TrimSpace(options.DiscoveryURL)
	options.QRAddr = strings.TrimSpace(options.QRAddr)
	if options.DiscoveryURL == "" {
		options.DiscoveryURL = defaultDiscoveryURL
	}
	if options.QRAddr == "" {
		options.QRAddr = defaultQRAddr
	}
	if options.Directory == "" {
		options.Directory = defaultCloneDirectory
	}
	parsed, err := url.Parse(options.DiscoveryURL)
	if err != nil {
		return CloneOptions{}, fmt.Errorf("invalid discovery URL %q: %w", options.DiscoveryURL, err)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" || parsed.Hostname() == "" {
		return CloneOptions{}, fmt.Errorf("invalid discovery URL %q: include http(s) scheme and host", options.DiscoveryURL)
	}
	if err := requireLoopbackAddr(options.QRAddr); err != nil {
		return CloneOptions{}, err
	}
	if options.Depth < 0 {
		return CloneOptions{}, fmt.Errorf("depth must be >= 0")
	}
	if options.Bare && !options.NoLFS {
		return CloneOptions{}, fmt.Errorf("--bare requires --no-lfs: LFS setup needs a working directory")
	}
	options.DiscoveryURL = parsed.String()
	return options, nil
}

// requireLoopbackAddr keeps the pairing QR, which carries the pairing secret,
// off every interface but loopback.
func requireLoopbackAddr(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("invalid QR address %q: %w", addr, err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("QR address must be a loopback address, got %q", addr)
	}
	return nil
}

// DeriveLFSURL ensures LFS traffic stays on the same origin as git by forcing the /lfs route.
func DeriveLFSURL(gitURL string) (string, error) {
	return lfsclient.DeriveEndpointURL(gitURL)
}

// StartQRServer serves the pairing QR on loopback. /payload.json exposes the
// same JSON the QR encodes so a scripted approver can read it without a camera.
func StartQRServer(payload string, addr string) (*http.Server, string, error) {
	if err := requireLoopbackAddr(addr); err != nil {
		return nil, "", err
	}
	png, err := qrcode.Encode(payload, qrcode.Medium, 300)
	if err != nil {
		return nil, "", fmt.Errorf("failed to encode QR code: %w", err)
	}
	dataURL := "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)
	page := buildQRPage(dataURL)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(page))
	})
	mux.HandleFunc("/payload.json", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(payload))
	})

	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, "", fmt.Errorf("failed to start QR listener: %w", err)
	}
	server := &http.Server{Handler: mux}
	go func() {
		_ = server.Serve(listener)
	}()
	return server, "http://" + listener.Addr().String(), nil
}

// PollPairingRecord waits until the sealed record appears at the slot derived
// from the pairing secret. A 404 means the other device has not approved yet.
// Any other status is a misconfigured discovery host and is reported.
func PollPairingRecord(ctx context.Context, discoveryURL, slot string, client *http.Client, interval time.Duration) ([]byte, error) {
	if client == nil {
		client = http.DefaultClient
	}
	if interval <= 0 {
		interval = discoveryPollInterval
	}
	endpoint, err := pairingRecordURL(discoveryURL, slot)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(pairingTimeout)
	if until, ok := ctx.Deadline(); ok && until.Before(deadline) {
		deadline = until
	}
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if err != nil {
			return nil, err
		}
		response, err := client.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
		} else {
			body, readErr := io.ReadAll(response.Body)
			response.Body.Close()
			if response.StatusCode == http.StatusOK {
				if readErr != nil {
					return nil, fmt.Errorf("read pairing record: %w", readErr)
				}
				return body, nil
			}
			if response.StatusCode != http.StatusNotFound {
				return nil, fmt.Errorf("discovery returned %s", response.Status)
			}
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("pairing record did not appear within %s", pairingTimeout)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(interval):
		}
	}
}

// pairingRecordURL inserts the slot as a subdomain so the address never
// appears in a request path an intermediary would log.
func pairingRecordURL(discoveryURL, slot string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(discoveryURL))
	if err != nil {
		return "", fmt.Errorf("invalid discovery URL %q: %w", discoveryURL, err)
	}
	host := parsed.Hostname()
	if host == "" {
		return "", fmt.Errorf("invalid discovery URL %q", discoveryURL)
	}
	if port := parsed.Port(); port != "" {
		parsed.Host = net.JoinHostPort(slot+"."+host, port)
	} else {
		parsed.Host = slot + "." + host
	}
	parsed.Path = "/"
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}

// PollAuthorization retries ls-remote until the paired device has committed
// this machine's key. It runs inside the repository so the remote helper can
// find the tailnet node.
func PollAuthorization(ctx context.Context, repoDir string, repoURL string, local gitcrypt.LocalIdentity, caFilePath string) error {
	for {
		err := RunGitWithMTLS(ctx, repoDir, caFilePath, local.ClientCertPath, local.ClientKeyPath, "ls-remote", "--heads", repoURL)
		if err == nil {
			return nil
		}
		if errors.Is(ctx.Err(), context.Canceled) {
			return fmt.Errorf("authorization canceled")
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("authorization canceled")
		case <-time.After(authPollInterval):
		}
	}
}

// InitializeRepository creates a local git directory before auth so per-repo identity can be stored in .git/replycant.
func InitializeRepository(ctx context.Context, directory string, repoURL string, bare bool) (string, error) {
	repoDir, err := resolveTargetRepoDir(directory, repoURL)
	if err != nil {
		return "", err
	}
	initArgs := []string{"init"}
	if bare {
		initArgs = append(initArgs, "--bare")
	}
	initArgs = append(initArgs, repoDir)
	if err := RunGit(ctx, "", initArgs...); err != nil {
		return "", err
	}
	if err := SetOriginRemote(ctx, repoDir, repoURL); err != nil {
		return "", err
	}
	return repoDir, nil
}

// SetOriginRemote ensures origin points at the requested URL even when retrying in an existing repo directory.
func SetOriginRemote(ctx context.Context, repoDir string, repoURL string) error {
	addErr := RunGit(ctx, repoDir, "remote", "add", "origin", repoURL)
	if addErr == nil {
		return nil
	}
	if err := RunGit(ctx, repoDir, "remote", "set-url", "origin", repoURL); err != nil {
		return fmt.Errorf("failed to configure origin remote: %w", addErr)
	}
	return nil
}

// FetchRepository downloads refs after authorization using repository-local mTLS material.
func FetchRepository(ctx context.Context, repoDir string, local gitcrypt.LocalIdentity, caFilePath string, depth int) error {
	args := []string{"fetch", "origin"}
	if depth > 0 {
		args = append(args, fmt.Sprintf("--depth=%d", depth))
	}
	return RunGitWithMTLSStreaming(ctx, repoDir, caFilePath, local.ClientCertPath, local.ClientKeyPath, args...)
}

// ResolveDefaultRemoteBranch identifies the remote HEAD branch so checkout matches server defaults.
func ResolveDefaultRemoteBranch(repoDir string) (string, error) {
	out, err := RunGitOutput(context.Background(), repoDir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
	if err == nil {
		trimmed := strings.TrimSpace(out)
		if trimmed != "" {
			return strings.TrimPrefix(trimmed, "origin/"), nil
		}
	}
	refsOutput, refsErr := RunGitOutput(context.Background(), repoDir, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin")
	if refsErr != nil {
		return "", fmt.Errorf("failed to resolve origin default branch: %w", err)
	}
	refs := strings.Split(strings.TrimSpace(refsOutput), "\n")
	candidates := map[string]bool{}
	for _, ref := range refs {
		trimmedRef := strings.TrimSpace(ref)
		if trimmedRef == "" || trimmedRef == "origin/HEAD" || !strings.HasPrefix(trimmedRef, "origin/") {
			continue
		}
		candidates[strings.TrimPrefix(trimmedRef, "origin/")] = true
	}
	for _, preferred := range []string{"main", "master"} {
		if candidates[preferred] {
			return preferred, nil
		}
	}
	remaining := make([]string, 0, len(candidates))
	for branch := range candidates {
		remaining = append(remaining, branch)
	}
	sort.Strings(remaining)
	if len(remaining) > 0 {
		return remaining[0], nil
	}
	return "", fmt.Errorf("failed to resolve origin default branch")
}

// CheckoutTrackingBranch materializes the remote default branch with upstream tracking in the fresh repository.
func CheckoutTrackingBranch(ctx context.Context, repoDir string, branch string) error {
	remoteRef := "origin/" + branch
	return RunGitStreaming(ctx, repoDir, "checkout", "-B", branch, "--track", remoteRef)
}

// RequireSupportedDatabaseVersionAtRef reads gitdb/version from a fetched
// ref so clone can abort before checkout or LFS smudge work. A missing
// path is version 0, the in-code stand-in for old alpha repositories.
func RequireSupportedDatabaseVersionAtRef(ctx context.Context, repoDir string, ref string) error {
	raw, err := RunGitOutput(ctx, repoDir, "show", ref+":"+gitcrypt.DatabaseVersionPath)
	if err != nil {
		if isAbsentDatabaseVersionAtRef(err) {
			return gitcrypt.RequireAcceptedDatabaseVersion(0)
		}
		return fmt.Errorf("read %s at %s: %w", gitcrypt.DatabaseVersionPath, ref, err)
	}
	return gitcrypt.RequireSupportedDatabaseVersion([]byte(raw))
}

// Distinguishes a missing gitdb/version path from other git failures
// so a bad ref still aborts clone instead of looking like version 0.
func isAbsentDatabaseVersionAtRef(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "does not exist") ||
		strings.Contains(msg, "exists on disk, but not in") ||
		strings.Contains(msg, "not a valid object name") ||
		strings.Contains(msg, "bad object")
}

// PreExtractEncryptionFiles materializes format and encryption metadata
// before LFS smudge runs on earlier-sorted binary paths.
func PreExtractEncryptionFiles(ctx context.Context, repoDir string, branch string) error {
	remoteRef := "origin/" + branch
	if err := RunGit(ctx, repoDir, "checkout", remoteRef, "--", "gitdb/", "encryption/"); err != nil {
		return fmt.Errorf("failed to pre-extract gitdb and encryption metadata from %s: %w", remoteRef, err)
	}
	return nil
}

// resolveTargetRepoDir mirrors git clone directory inference while ensuring downstream identity writes use an absolute path.
func resolveTargetRepoDir(directory string, repoURL string) (string, error) {
	if directory != "" {
		abs, err := filepath.Abs(directory)
		if err != nil {
			return "", fmt.Errorf("failed to resolve clone directory: %w", err)
		}
		if err := os.Mkdir(abs, 0o755); err != nil {
			if os.IsExist(err) {
				return "", fmt.Errorf("destination path %q already exists", abs)
			}
			return "", fmt.Errorf("failed to create clone directory %q: %w", abs, err)
		}
		return abs, nil
	}
	dir, err := inferCloneDirectory(repoURL)
	if err != nil {
		return "", err
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", fmt.Errorf("failed to resolve clone directory: %w", err)
	}
	if err := os.Mkdir(abs, 0o755); err != nil {
		if os.IsExist(err) {
			return "", fmt.Errorf("destination path %q already exists", abs)
		}
		return "", fmt.Errorf("failed to create clone directory %q: %w", abs, err)
	}
	return abs, nil
}

// ConfigureRepository installs filter and TLS settings so normal git commands transparently decrypt/encrypt manifests.
func ConfigureRepository(repoDir string, lfsURL string, local gitcrypt.LocalIdentity, caFilePath string) error {
	ctx := context.Background()
	if err := appendRepoAttributes(repoDir, "manifests/** filter=replycant-crypt"); err != nil {
		return err
	}
	if err := appendRepoAttributes(repoDir, "manifests/** diff=replycant-crypt"); err != nil {
		return err
	}
	if err := RunGit(ctx, repoDir, "config", "--local", "filter.replycant-crypt.process", "git-replycant filter-process"); err != nil {
		return err
	}
	if err := RunGit(ctx, repoDir, "config", "--local", "filter.replycant-crypt.required", "true"); err != nil {
		return err
	}
	if err := RunGit(ctx, repoDir, "config", "--local", "diff.replycant-crypt.textconv", "git-replycant smudge"); err != nil {
		return err
	}
	if err := RunGit(ctx, repoDir, "config", "--local", "diff.replycant-crypt.cachetextconv", "true"); err != nil {
		return err
	}
	if err := RunGit(ctx, repoDir, "config", "--local", "http.sslCAInfo", caFilePath); err != nil {
		return err
	}
	if err := RunGit(ctx, repoDir, "config", "--local", "http.sslCert", local.ClientCertPath); err != nil {
		return err
	}
	if err := RunGit(ctx, repoDir, "config", "--local", "http.sslKey", local.ClientKeyPath); err != nil {
		return err
	}
	if lfsURL != "" {
		if err := EnsureGitLFSAvailable(repoDir); err != nil {
			return err
		}
		if err := RunGit(ctx, repoDir, "config", "--local", "lfs.url", lfsURL); err != nil {
			return err
		}
		if err := appendRepoAttributes(repoDir, "binary/** filter=replycant-crypt"); err != nil {
			return err
		}
		if err := installReplycantPrePushHook(repoDir); err != nil {
			return err
		}
	}
	return nil
}

// EnsureGitLFSAvailable fails fast when LFS integration is requested but git-lfs is not installed.
func EnsureGitLFSAvailable(repoDir string) error {
	if err := RunGit(context.Background(), repoDir, "lfs", "version"); err == nil {
		return nil
	}
	cmd := exec.Command("git-lfs", "version")
	cmd.Env = gitNonInteractiveEnv()
	cmd.Dir = repoDir
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("git-lfs is required when LFS integration is enabled: %v: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

// RunGitWithMTLS runs a git command with CA/cert/key options so gitd mTLS auth succeeds.
func RunGitWithMTLS(ctx context.Context, repoDir string, caFile string, certFile string, keyFile string, args ...string) error {
	mtlsArgs := []string{
		"-c", "http.sslCAInfo=" + caFile,
		"-c", "http.sslCert=" + certFile,
		"-c", "http.sslKey=" + keyFile,
	}
	mtlsArgs = append(mtlsArgs, args...)
	return RunGit(ctx, repoDir, mtlsArgs...)
}

// RunGitWithMTLSStreaming runs mTLS-protected git commands while preserving real-time command progress output.
func RunGitWithMTLSStreaming(ctx context.Context, repoDir string, caFile string, certFile string, keyFile string, args ...string) error {
	mtlsArgs := []string{
		"-c", "http.sslCAInfo=" + caFile,
		"-c", "http.sslCert=" + certFile,
		"-c", "http.sslKey=" + keyFile,
	}
	mtlsArgs = append(mtlsArgs, args...)
	return RunGitStreaming(ctx, repoDir, mtlsArgs...)
}

// RunGit centralizes command execution so errors include command stderr for troubleshooting.
func RunGit(ctx context.Context, repoDir string, args ...string) error {
	cmd := exec.CommandContext(ctx, "git", args...)
	if repoDir != "" {
		cmd.Dir = repoDir
	}
	cmd.Env = gitNonInteractiveEnv()
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	return fmt.Errorf("git %s failed: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
}

// RunGitStreaming executes long-running git operations directly on terminal streams so users see live progress.
func RunGitStreaming(ctx context.Context, repoDir string, args ...string) error {
	cmd := exec.CommandContext(ctx, "git", args...)
	if repoDir != "" {
		cmd.Dir = repoDir
	}
	cmd.Env = gitStreamingEnv()
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("git %s failed: %w", strings.Join(args, " "), err)
	}
	return nil
}

// RunGitOutput centralizes git stdout capture for control-flow decisions while preserving rich command errors.
func RunGitOutput(ctx context.Context, repoDir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	if repoDir != "" {
		cmd.Dir = repoDir
	}
	cmd.Env = gitNonInteractiveEnv()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s failed: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return string(output), nil
}

// gitNonInteractiveEnv prevents credential prompts so onboarding only relies on mTLS authorization.
func gitNonInteractiveEnv() []string {
	env := append([]string{}, os.Environ()...)
	env = append(env,
		"GIT_TERMINAL_PROMPT=0",
		"GIT_ASKPASS=",
		"SSH_ASKPASS=",
		"GCM_INTERACTIVE=never",
	)
	return env
}

// gitStreamingEnv enables non-interactive auth plus forced LFS progress for commands that run for a long time.
func gitStreamingEnv() []string {
	env := gitNonInteractiveEnv()
	return append(env, "GIT_LFS_FORCE_PROGRESS=1")
}

// appendRepoAttributes ensures the filter rule exists without duplicating lines on repeated runs.
func appendRepoAttributes(repoDir string, line string) error {
	gitDir, err := resolveGitDir(repoDir)
	if err != nil {
		return err
	}
	infoDir := filepath.Join(gitDir, "info")
	if err := os.MkdirAll(infoDir, 0o755); err != nil {
		return fmt.Errorf("failed to create .git/info: %w", err)
	}
	path := filepath.Join(infoDir, "attributes")
	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to read .git/info/attributes: %w", err)
	}
	lines := strings.Split(string(existing), "\n")
	for _, existingLine := range lines {
		if strings.TrimSpace(existingLine) == line {
			return nil
		}
	}
	content := strings.TrimRight(string(existing), "\n")
	if strings.TrimSpace(content) == "" {
		content = line + "\n"
	} else {
		content = content + "\n" + line + "\n"
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return fmt.Errorf("failed to write .git/info/attributes: %w", err)
	}
	return nil
}

// installReplycantPrePushHook ensures git push always uploads Replycant LFS objects before refs advance.
func installReplycantPrePushHook(repoDir string) error {
	gitDir, err := resolveGitDir(repoDir)
	if err != nil {
		return err
	}
	hooksDir := filepath.Join(gitDir, "hooks")
	if err := os.MkdirAll(hooksDir, 0o755); err != nil {
		return fmt.Errorf("failed to create hooks directory: %w", err)
	}
	hookPath := filepath.Join(hooksDir, "pre-push")
	content := "#!/bin/sh\nexec git-replycant pre-push \"$@\"\n"
	if err := os.WriteFile(hookPath, []byte(content), 0o755); err != nil {
		return fmt.Errorf("failed to write pre-push hook: %w", err)
	}
	return nil
}

// inferCloneDirectory reproduces git clone destination naming for URL-only invocations.
func inferCloneDirectory(repoURL string) (string, error) {
	if parsed, err := url.Parse(repoURL); err == nil {
		name := path.Base(parsed.Path)
		name = strings.TrimSuffix(name, ".git")
		if name != "" && name != "." && name != "/" {
			return name, nil
		}
		if host := parsed.Hostname(); host != "" {
			return host, nil
		}
	}
	return "", fmt.Errorf("unable to infer clone directory from %q", repoURL)
}

// buildQRPage keeps local onboarding UI dependency-free while clearly showing scan instructions.
func buildQRPage(dataURL string) string {
	return "<!doctype html><html><head><meta charset=\"utf-8\"><title>Replycant Authorization</title></head>" +
		"<body style=\"font-family:sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;background:#111;color:#fff;\">" +
		"<div style=\"text-align:center;background:#1d1d1d;padding:24px;border-radius:12px;box-shadow:0 8px 24px rgba(0,0,0,0.4)\">" +
		"<h1>Authorize this device</h1>" +
		"<p>Scan this QR code with the Replycant iOS app.</p>" +
		"<img alt=\"replycant onboarding qr\" width=\"300\" height=\"300\" src=\"" + html.EscapeString(dataURL) + "\"/>" +
		"</div></body></html>"
}
