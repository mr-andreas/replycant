package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
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
	"github.com/mr-andreas/replycant/pkg/mdns"
	"github.com/skip2/go-qrcode"
)

const (
	// authPollInterval controls how frequently clone onboarding retries repository auth checks.
	authPollInterval = 3 * time.Second
)

// CloneOptions captures CLI inputs required for onboarding and repository clone setup.
type CloneOptions struct {
	ServerURL  string
	DeviceName string
	Depth      int
	Bare       bool
	NoLFS      bool
	Directory  string
}

// DiscoveredServerConfig captures caserver discovery fields needed to bootstrap clone trust and remotes.
type DiscoveredServerConfig struct {
	CA  string `json:"ca"`
	URL string `json:"url"`
}

// RunCloneCommand orchestrates QR onboarding and clone initialization for replycant repositories.
func RunCloneCommand(options CloneOptions) error {
	options, err := NormalizeCloneOptions(options)
	if err != nil {
		return err
	}
	discovered, err := DiscoverServerConfig(options.ServerURL)
	if err != nil {
		return err
	}
	lfsURL, err := DeriveLFSURL(discovered.URL)
	if err != nil {
		return err
	}
	if options.NoLFS {
		lfsURL = ""
	}
	caHash, err := gitcrypt.ComputeCAHash(discovered.CA)
	if err != nil {
		return fmt.Errorf("failed to compute discovered CA hash: %w", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	repoDir, err := InitializeRepository(ctx, options.Directory, discovered.URL, options.ServerURL, options.Bare)
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
	caFilePath, err := WriteCAToRepoReplycantDir(discovered.CA, local.ConfigDirectory)
	if err != nil {
		return err
	}

	qrPayload, err := gitcrypt.BuildPublicKeyQrPayload(local.Identity, caHash)
	if err != nil {
		return err
	}
	server, baseURL, err := StartQRServer(qrPayload)
	if err != nil {
		return err
	}
	defer server.Close()
	fmt.Fprintf(os.Stderr, "Open %s to view the authorization QR code.\n", baseURL)
	fmt.Fprintln(os.Stderr, "Waiting for repository authorization...")

	if err := PollAuthorization(ctx, discovered.URL, local, caFilePath); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Authorization confirmed. Proceeding with clone.")

	if err := server.Close(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("failed to stop QR server: %w", err)
	}
	if err := FetchRepository(ctx, repoDir, local, caFilePath, options.Depth); err != nil {
		return err
	}
	defaultBranch, err := ResolveDefaultRemoteBranch(repoDir)
	if err != nil {
		return err
	}
	if err := RequireSupportedDatabaseVersionAtRef(ctx, repoDir, "origin/"+defaultBranch); err != nil {
		return err
	}
	if err := ConfigureRepository(repoDir, lfsURL, local, caFilePath); err != nil {
		return err
	}
	if options.Bare {
		fmt.Fprintf(os.Stderr, "Clone complete and filters configured in %s\n", repoDir)
		return nil
	}
	if err := PreExtractEncryptionFiles(ctx, repoDir, defaultBranch); err != nil {
		return err
	}
	if err := CheckoutTrackingBranch(ctx, repoDir, defaultBranch); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Clone complete and filters configured in %s\n", repoDir)
	return nil
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

// NormalizeCloneOptions validates and normalizes parsed clone options before clone side effects run.
func NormalizeCloneOptions(options CloneOptions) (CloneOptions, error) {
	options.ServerURL = strings.TrimSpace(options.ServerURL)
	options.DeviceName = strings.TrimSpace(options.DeviceName)
	options.Directory = strings.TrimSpace(options.Directory)
	if options.ServerURL == "" {
		return CloneOptions{}, fmt.Errorf("server URL is required")
	}
	parsed, err := url.Parse(options.ServerURL)
	if err != nil {
		return CloneOptions{}, fmt.Errorf("invalid server URL %q: %w", options.ServerURL, err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return CloneOptions{}, fmt.Errorf("invalid server URL %q: include scheme and host", options.ServerURL)
	}
	if options.Depth < 0 {
		return CloneOptions{}, fmt.Errorf("depth must be >= 0")
	}
	if options.Bare && !options.NoLFS {
		return CloneOptions{}, fmt.Errorf("--bare requires --no-lfs: LFS setup needs a working directory")
	}
	options.ServerURL = parsed.String()
	return options, nil
}

// DiscoverServerConfig fetches caserver config so clone can bootstrap CA trust without local files.
func DiscoverServerConfig(serverURL string) (DiscoveredServerConfig, error) {
	baseURL, err := url.Parse(strings.TrimSpace(serverURL))
	if err != nil {
		return DiscoveredServerConfig{}, fmt.Errorf("invalid server URL %q: %w", serverURL, err)
	}
	endpoint := baseURL.ResolveReference(&url.URL{Path: "./config.json"})
	response, err := buildDiscoveryHTTPClient().Get(endpoint.String())
	if err != nil {
		return DiscoveredServerConfig{}, fmt.Errorf("failed to fetch server config %s: %w", endpoint.String(), err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return DiscoveredServerConfig{}, fmt.Errorf("server config request failed with status %s", response.Status)
	}
	var config DiscoveredServerConfig
	if err := json.NewDecoder(response.Body).Decode(&config); err != nil {
		return DiscoveredServerConfig{}, fmt.Errorf("failed to decode server config response: %w", err)
	}
	if strings.TrimSpace(config.CA) == "" {
		return DiscoveredServerConfig{}, fmt.Errorf("server config response is missing ca")
	}
	if strings.TrimSpace(config.URL) == "" {
		return DiscoveredServerConfig{}, fmt.Errorf("server config response is missing url")
	}
	config.CA = strings.TrimSpace(config.CA)
	config.URL = strings.TrimSpace(config.URL)
	return config, nil
}

// buildDiscoveryHTTPClient ensures clone discovery can still reach `.local` servers in static binaries.
func buildDiscoveryHTTPClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			DialContext: mdns.DialContext,
		},
	}
}

// DeriveLFSURL ensures LFS traffic stays on the same origin as git by forcing the /lfs route.
func DeriveLFSURL(gitURL string) (string, error) {
	return lfsclient.DeriveEndpointURL(gitURL)
}

// StartQRServer serves a local page with the onboarding QR payload so mobile authorization can proceed.
func StartQRServer(payload string) (*http.Server, string, error) {
	png, err := qrcode.Encode(payload, qrcode.Medium, 300)
	if err != nil {
		return nil, "", fmt.Errorf("failed to encode QR code: %w", err)
	}
	dataURL := "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)
	page := buildQRPage(dataURL)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(page))
	})

	listener, err := net.Listen("tcp", "0.0.0.0:0")
	if err != nil {
		return nil, "", fmt.Errorf("failed to start QR listener: %w", err)
	}
	server := &http.Server{Handler: mux}
	go func() {
		_ = server.Serve(listener)
	}()
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		return nil, "", fmt.Errorf("failed to resolve QR listener port: %w", err)
	}
	return server, "http://127.0.0.1:" + port, nil
}

// PollAuthorization retries ls-remote until credentials are accepted or the user aborts.
func PollAuthorization(ctx context.Context, repoURL string, local gitcrypt.LocalIdentity, caFilePath string) error {
	for {
		err := RunGitWithMTLS(ctx, "", caFilePath, local.ClientCertPath, local.ClientKeyPath, "ls-remote", "--heads", repoURL)
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
func InitializeRepository(ctx context.Context, directory string, repoURL string, inferURL string, bare bool) (string, error) {
	repoDir, err := resolveTargetRepoDir(directory, inferURL)
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
