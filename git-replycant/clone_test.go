package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestNormalizeCloneOptions ensures CLI clone input validation fails fast on invalid arguments.
func TestNormalizeCloneOptions(t *testing.T) {
	t.Parallel()
	_, err := NormalizeCloneOptions(CloneOptions{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "server URL is required")

	_, err = NormalizeCloneOptions(CloneOptions{ServerURL: "not-a-url"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid server URL")

	_, err = NormalizeCloneOptions(CloneOptions{
		ServerURL: "http://127.0.0.1:8080",
		Bare:      true,
		NoLFS:     false,
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--bare requires --no-lfs")

	opts, err := NormalizeCloneOptions(CloneOptions{
		ServerURL:  " http://127.0.0.1:8080 ",
		DeviceName: " test ",
	})
	require.NoError(t, err)
	assert.Equal(t, "http://127.0.0.1:8080", opts.ServerURL)
	assert.Equal(t, "test", opts.DeviceName)
}

// TestInferCloneDirectory validates destination inference compatibility with common git URL shapes.
func TestInferCloneDirectory(t *testing.T) {
	t.Parallel()
	tests := []struct {
		url     string
		want    string
		wantErr bool
	}{
		{url: "https://example.com/repo.git", want: "repo"},
		{url: "https://example.com/repo", want: "repo"},
		{url: "https://example.com/repo/", want: "repo"},
		{url: "https://example.com/", want: "example.com"},
		{url: "http://replycant.local:8080", want: "replycant.local"},
		{url: "http://replycant.local:8080/", want: "replycant.local"},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.url, func(t *testing.T) {
			t.Parallel()
			got, err := inferCloneDirectory(tt.url)
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

// TestWriteCAToRepoReplycantDir ensures clone setup persists discovered CA bytes in a stable repo-local path.
func TestWriteCAToRepoReplycantDir(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()

	destDir := filepath.Join(tmp, "repo", ".git", "replycant")
	destPath, err := WriteCAToRepoReplycantDir("ca-data", destDir)
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(destDir, "ca.pem"), destPath)

	raw, err := os.ReadFile(destPath)
	require.NoError(t, err)
	assert.Equal(t, []byte("ca-data"), raw)

	info, err := os.Stat(destPath)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
}

// TestDiscoverServerConfig ensures clone discovery reads the same config contract used by browser onboarding.
func TestDiscoverServerConfig(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(DiscoveredServerConfig{
			CA:  "pem",
			URL: "https://git.example.test/repo.git",
		})
	}))
	defer server.Close()

	config, err := DiscoverServerConfig(server.URL)
	require.NoError(t, err)
	assert.Equal(t, "pem", config.CA)
	assert.Equal(t, "https://git.example.test/repo.git", config.URL)
}

// TestBuildDiscoveryHTTPClientUsesMDNSDial ensures clone config discovery can resolve `.local` hosts.
func TestBuildDiscoveryHTTPClientUsesMDNSDial(t *testing.T) {
	t.Parallel()
	client := buildDiscoveryHTTPClient()
	require.NotNil(t, client)
	transport, ok := client.Transport.(*http.Transport)
	require.True(t, ok)
	require.NotNil(t, transport.DialContext)
}

// TestDeriveLFSURL ensures clone setup always places LFS on the git origin using the /lfs route.
func TestDeriveLFSURL(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		gitURL string
		want   string
	}{
		{name: "keep host and port", gitURL: "https://git.example:8443/repo.git", want: "https://git.example:8443/lfs"},
		{name: "trim path and query", gitURL: "https://git.example/path/repo.git?x=1#ref", want: "https://git.example/lfs"},
		{name: "drop credentials", gitURL: "https://user:pass@git.example/repo.git", want: "https://git.example/lfs"},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			got, err := DeriveLFSURL(tt.gitURL)
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

// TestStartQRServerReachability ensures QR onboarding serves localhost-friendly URLs while listening on all interfaces.
func TestStartQRServerReachability(t *testing.T) {
	t.Parallel()

	server, baseURL, err := StartQRServer("qr-payload")
	require.NoError(t, err)
	defer server.Close()

	parsedBaseURL, err := url.Parse(baseURL)
	require.NoError(t, err)
	assert.Equal(t, "127.0.0.1", parsedBaseURL.Hostname())
	port := parsedBaseURL.Port()
	require.NotEmpty(t, port)

	resp, err := http.Get(baseURL)
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = resp.Body.Close()
	})
	assert.Equal(t, http.StatusOK, resp.StatusCode)
	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	assert.Contains(t, string(body), "Scan this QR code with the Replycant iOS app.")

	bindAddr := chooseReachableBindAddress(t)
	if bindAddr == "" {
		t.Skip("no non-loopback IPv4 address available")
	}
	bindURL := "http://" + net.JoinHostPort(bindAddr, port)
	bindResp, err := http.Get(bindURL)
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = bindResp.Body.Close()
	})
	assert.Equal(t, http.StatusOK, bindResp.StatusCode)
}

// chooseReachableBindAddress selects a non-loopback IPv4 address so tests can verify all-interface listeners.
func chooseReachableBindAddress(t *testing.T) string {
	t.Helper()

	addrs, err := net.InterfaceAddrs()
	require.NoError(t, err)
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP == nil {
			continue
		}
		ip := ipNet.IP.To4()
		if ip == nil || ip.IsLoopback() {
			continue
		}
		return ip.String()
	}
	return ""
}

// TestGitNonInteractiveEnv verifies clone-side git execution never prompts for credentials.
func TestGitNonInteractiveEnv(t *testing.T) {
	t.Parallel()
	env := gitNonInteractiveEnv()
	assert.Contains(t, env, "GIT_TERMINAL_PROMPT=0")
	assert.Contains(t, env, "GIT_ASKPASS=")
	assert.Contains(t, env, "SSH_ASKPASS=")
	assert.Contains(t, env, "GCM_INTERACTIVE=never")
}

// TestGitStreamingEnv ensures long-running clone operations force non-interactive LFS progress output.
func TestGitStreamingEnv(t *testing.T) {
	t.Parallel()
	env := gitStreamingEnv()
	assert.Contains(t, env, "GIT_TERMINAL_PROMPT=0")
	assert.Contains(t, env, "GIT_LFS_FORCE_PROGRESS=1")
}

// TestRunGitStreaming shows command output immediately and keeps required non-interactive/LFS env flags.
func TestRunGitStreaming(t *testing.T) {
	fakeGit := buildFakeGitStreamingBinary(t)
	t.Setenv("PATH", filepath.Dir(fakeGit)+string(os.PathListSeparator)+os.Getenv("PATH"))

	stdoutReader, stdoutWriter, err := os.Pipe()
	require.NoError(t, err)
	stderrReader, stderrWriter, err := os.Pipe()
	require.NoError(t, err)

	originalStdout := os.Stdout
	originalStderr := os.Stderr
	os.Stdout = stdoutWriter
	os.Stderr = stderrWriter
	t.Cleanup(func() {
		os.Stdout = originalStdout
		os.Stderr = originalStderr
		_ = stdoutWriter.Close()
		_ = stderrWriter.Close()
		_ = stdoutReader.Close()
		_ = stderrReader.Close()
	})

	require.NoError(t, RunGitStreaming(context.Background(), "", "status"))

	require.NoError(t, stdoutWriter.Close())
	require.NoError(t, stderrWriter.Close())
	stdoutOutput, err := io.ReadAll(stdoutReader)
	require.NoError(t, err)
	stderrOutput, err := io.ReadAll(stderrReader)
	require.NoError(t, err)

	assert.Contains(t, string(stdoutOutput), "streamed stdout line")
	assert.Contains(t, string(stderrOutput), "streamed stderr line")
}

// TestRequireSupportedDatabaseVersionAtRef accepts a missing marker as
// version 0 and refuses any other unsupported integer.
func TestRequireSupportedDatabaseVersionAtRef(t *testing.T) {
	t.Parallel()
	repoDir := testInitRepo(t)
	testWriteFile(t, filepath.Join(repoDir, "notes", "readme.txt"), []byte("hello"), 0o644)
	testRunGit(t, repoDir, "add", ".")
	testRunGit(t, repoDir, "commit", "-m", "seed")
	require.NoError(t, RequireSupportedDatabaseVersionAtRef(context.Background(), repoDir, "HEAD"))

	testWriteFile(t, filepath.Join(repoDir, "gitdb", "version"), []byte("1\n"), 0o644)
	testRunGit(t, repoDir, "add", ".")
	testRunGit(t, repoDir, "commit", "-m", "marker")
	require.NoError(t, RequireSupportedDatabaseVersionAtRef(context.Background(), repoDir, "HEAD"))

	testWriteFile(t, filepath.Join(repoDir, "gitdb", "version"), []byte("2\n"), 0o644)
	testRunGit(t, repoDir, "add", ".")
	testRunGit(t, repoDir, "commit", "-m", "bump")
	err := RequireSupportedDatabaseVersionAtRef(context.Background(), repoDir, "HEAD")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unsupported gitdb database version 2")
}

// TestInitializeRepository confirms init + origin setup works before network authorization.
func TestInitializeRepository(t *testing.T) {
	repoParent := t.TempDir()
	target := filepath.Join(repoParent, "cloned")
	repoURL := "https://example.com/repo.git"
	repoDir, err := InitializeRepository(context.Background(), target, repoURL, "http://example.com:8080", false)
	require.NoError(t, err)
	assert.Equal(t, target, repoDir)
	assert.DirExists(t, filepath.Join(repoDir, ".git"))

	origin := strings.TrimSpace(testRunGit(t, repoDir, "remote", "get-url", "origin"))
	assert.Equal(t, repoURL, origin)
}

// TestInitializeRepositoryRejectsExistingDirectory ensures clone target collisions fail early like git clone.
func TestInitializeRepositoryRejectsExistingDirectory(t *testing.T) {
	repoParent := t.TempDir()
	target := filepath.Join(repoParent, "cloned")
	require.NoError(t, os.Mkdir(target, 0o755))

	_, err := InitializeRepository(context.Background(), target, "https://example.com/repo.git", "http://example.com:8080", false)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "already exists")
}

// TestInitializeRepositoryBare confirms bare init + origin setup works for server-side repository clones.
func TestInitializeRepositoryBare(t *testing.T) {
	repoParent := t.TempDir()
	target := filepath.Join(repoParent, "cloned.git")
	repoURL := "https://example.com/repo.git"
	repoDir, err := InitializeRepository(context.Background(), target, repoURL, "http://example.com:8080", true)
	require.NoError(t, err)
	assert.Equal(t, target, repoDir)
	assert.DirExists(t, repoDir)
	assert.NoDirExists(t, filepath.Join(repoDir, ".git"))
	assert.Equal(t, "true", strings.TrimSpace(testRunGit(t, repoDir, "rev-parse", "--is-bare-repository")))

	origin := strings.TrimSpace(testRunGit(t, repoDir, "remote", "get-url", "origin"))
	assert.Equal(t, repoURL, origin)
}

// TestSetOriginRemote ensures repeated setup updates origin URLs cleanly.
func TestSetOriginRemote(t *testing.T) {
	repo := testInitRepo(t)
	require.NoError(t, SetOriginRemote(context.Background(), repo, "https://example.com/a.git"))
	origin := strings.TrimSpace(testRunGit(t, repo, "remote", "get-url", "origin"))
	assert.Equal(t, "https://example.com/a.git", origin)

	require.NoError(t, SetOriginRemote(context.Background(), repo, "https://example.com/b.git"))
	origin = strings.TrimSpace(testRunGit(t, repo, "remote", "get-url", "origin"))
	assert.Equal(t, "https://example.com/b.git", origin)
}

// TestAppendRepoAttributes verifies filter attributes remain idempotent across repeated configuration.
func TestAppendRepoAttributes(t *testing.T) {
	repo := testInitRepo(t)
	require.NoError(t, appendRepoAttributes(repo, "manifests/** filter=replycant-crypt"))
	require.NoError(t, appendRepoAttributes(repo, "manifests/** filter=replycant-crypt"))
	require.NoError(t, appendRepoAttributes(repo, "manifests/** diff=replycant-crypt"))

	attrsPath := filepath.Join(repo, ".git", "info", "attributes")
	raw, err := os.ReadFile(attrsPath)
	require.NoError(t, err)
	content := string(raw)
	assert.Equal(t, 1, strings.Count(content, "manifests/** filter=replycant-crypt"))
	assert.Equal(t, 1, strings.Count(content, "manifests/** diff=replycant-crypt"))
}

// TestConfigureRepository validates local filter, diff, and TLS git config are wired in one call.
func TestConfigureRepository(t *testing.T) {
	repo := testInitRepo(t)
	ca := filepath.Join(t.TempDir(), "ca.pem")
	cert := filepath.Join(t.TempDir(), "client-cert.pem")
	key := filepath.Join(t.TempDir(), "client-key.pem")
	testWriteFile(t, ca, []byte("ca"), 0o644)
	testWriteFile(t, cert, []byte("cert"), 0o644)
	testWriteFile(t, key, []byte("key"), 0o600)

	local := gitcrypt.LocalIdentity{ClientCertPath: cert, ClientKeyPath: key}
	require.NoError(t, ConfigureRepository(repo, "", local, ca))

	assert.Equal(t, "git-replycant filter-process", strings.TrimSpace(testRunGit(t, repo, "config", "--local", "--get", "filter.replycant-crypt.process")))
	assert.Equal(t, "true", strings.TrimSpace(testRunGit(t, repo, "config", "--local", "--get", "filter.replycant-crypt.required")))
	assert.Equal(t, "git-replycant smudge", strings.TrimSpace(testRunGit(t, repo, "config", "--local", "--get", "diff.replycant-crypt.textconv")))
	assert.Equal(t, "true", strings.TrimSpace(testRunGit(t, repo, "config", "--local", "--get", "diff.replycant-crypt.cachetextconv")))
	assert.Equal(t, ca, strings.TrimSpace(testRunGit(t, repo, "config", "--local", "--get", "http.sslCAInfo")))
	assert.Equal(t, cert, strings.TrimSpace(testRunGit(t, repo, "config", "--local", "--get", "http.sslCert")))
	assert.Equal(t, key, strings.TrimSpace(testRunGit(t, repo, "config", "--local", "--get", "http.sslKey")))

	raw, err := os.ReadFile(filepath.Join(repo, ".git", "info", "attributes"))
	require.NoError(t, err)
	assert.Contains(t, string(raw), "manifests/** filter=replycant-crypt")
	assert.Contains(t, string(raw), "manifests/** diff=replycant-crypt")
}

// TestConfigureRepositoryInstallsPrePushHook verifies LFS-enabled clone setup installs Replycant pre-push uploads.
func TestConfigureRepositoryInstallsPrePushHook(t *testing.T) {
	repo := testInitRepo(t)
	fakeLFS := buildFakeGitLFSVersionBinary(t)
	t.Setenv("PATH", filepath.Dir(fakeLFS)+string(os.PathListSeparator)+os.Getenv("PATH"))

	ca := filepath.Join(t.TempDir(), "ca.pem")
	cert := filepath.Join(t.TempDir(), "client-cert.pem")
	key := filepath.Join(t.TempDir(), "client-key.pem")
	testWriteFile(t, ca, []byte("ca"), 0o644)
	testWriteFile(t, cert, []byte("cert"), 0o644)
	testWriteFile(t, key, []byte("key"), 0o600)

	local := gitcrypt.LocalIdentity{ClientCertPath: cert, ClientKeyPath: key}
	require.NoError(t, ConfigureRepository(repo, "http://lfs.example.test", local, ca))

	assert.Equal(t, "http://lfs.example.test", strings.TrimSpace(testRunGit(t, repo, "config", "--local", "--get", "lfs.url")))
	raw, err := os.ReadFile(filepath.Join(repo, ".git", "hooks", "pre-push"))
	require.NoError(t, err)
	assert.Equal(t, "#!/bin/sh\nexec git-replycant pre-push \"$@\"\n", string(raw))
}

// buildFakeGitStreamingBinary creates a git shim that validates env propagation and emits streamable output.
func buildFakeGitStreamingBinary(t *testing.T) string {
	t.Helper()
	outputPath := filepath.Join(t.TempDir(), "git")
	sourcePath := filepath.Join(t.TempDir(), "fake_git_streaming.go")
	source := `package main
import (
	"fmt"
	"os"
)

func main() {
	if os.Getenv("GIT_TERMINAL_PROMPT") != "0" {
		fmt.Fprintln(os.Stderr, "missing GIT_TERMINAL_PROMPT=0")
		os.Exit(2)
	}
	if os.Getenv("GIT_LFS_FORCE_PROGRESS") != "1" {
		fmt.Fprintln(os.Stderr, "missing GIT_LFS_FORCE_PROGRESS=1")
		os.Exit(3)
	}
	fmt.Fprintln(os.Stdout, "streamed stdout line")
	fmt.Fprintln(os.Stderr, "streamed stderr line")
}
`
	require.NoError(t, os.WriteFile(sourcePath, []byte(source), 0o644))
	cmd := exec.Command("go", "build", "-o", outputPath, sourcePath)
	buildOutput, err := cmd.CombinedOutput()
	require.NoErrorf(t, err, "failed to build fake streaming git: %s", string(buildOutput))
	require.NoError(t, os.Chmod(outputPath, 0o755))
	return outputPath
}

// buildFakeGitLFSVersionBinary provides the minimal git-lfs interface needed by ConfigureRepository tests.
func buildFakeGitLFSVersionBinary(t *testing.T) string {
	t.Helper()
	outputPath := filepath.Join(t.TempDir(), "git-lfs")
	sourcePath := filepath.Join(t.TempDir(), "fake_git_lfs_version.go")
	source := `package main
import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "version" {
		fmt.Println("git-lfs/3.0.0-fake")
		return
	}
	os.Exit(1)
}
`
	require.NoError(t, os.WriteFile(sourcePath, []byte(source), 0o644))
	cmd := exec.Command("go", "build", "-o", outputPath, sourcePath)
	buildOutput, err := cmd.CombinedOutput()
	require.NoErrorf(t, err, "failed to build fake git-lfs: %s", string(buildOutput))
	require.NoError(t, os.Chmod(outputPath, 0o755))
	return outputPath
}
