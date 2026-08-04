package gitd

import (
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/http/cgi"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/go-git/go-git/v5"
	"github.com/mr-andreas/replycant/server/gitd/auth"
)

// Interface fullfilled by the auth.Authenticator.
type Authenticator interface {
	Authenticate(clientCert *x509.Certificate) (string, error)
}

// Collects the repository and backend service upstreams gitd fronts. Grouping
// them keeps the constructor readable as more services move behind the single
// mTLS endpoint, and lets callers omit services they do not run.
type ServerConfig struct {
	RepoPath      string
	LfsURL        string
	DecryptdURL   string
	TranscodedURL string
}

// Implements http.Handler for Git Smart HTTP protocol with mTLS authentication.
// Wraps git-http-backend to provide secure, authenticated access to a Git repository.
type Server struct {
	repoPath       string
	auth           Authenticator
	gitBackendPath string
	lfsURL         string
	serviceProxies []*serviceProxy

	bootstrapMu sync.Mutex // Prevents race condition during initial repository bootstrap
}

// Creates a new gitd server that requires mTLS authentication.
// Clients must present certificates with authorized P-256 ECDSA public keys.
func NewServer(a Authenticator, cfg ServerConfig) (*Server, error) {
	if err := ValidateRepository(cfg.RepoPath); err != nil {
		return nil, err
	}

	gitBackendPath, err := findGitHttpBackend()
	if err != nil {
		return nil, fmt.Errorf("git-http-backend not found: %w", err)
	}

	proxies, err := buildServiceProxies(cfg)
	if err != nil {
		return nil, err
	}

	server := &Server{
		repoPath:       cfg.RepoPath,
		auth:           a,
		gitBackendPath: gitBackendPath,
		lfsURL:         cfg.LfsURL,
		serviceProxies: proxies,
	}

	if err := server.installPreReceiveHook(); err != nil {
		return nil, err
	}

	return server, nil
}

// Builds the ordered proxy routing table, skipping services left unconfigured.
func buildServiceProxies(cfg ServerConfig) ([]*serviceProxy, error) {
	specs := []struct {
		pathPrefix              string
		upstreamURL             string
		rewritesLFSBatchActions bool
	}{
		{lfsProxyPathPrefix, cfg.LfsURL, true},
		{decryptdProxyPathPrefix, cfg.DecryptdURL, false},
		{transcodedProxyPathPrefix, cfg.TranscodedURL, false},
	}

	proxies := make([]*serviceProxy, 0, len(specs))
	for _, spec := range specs {
		proxy, err := newServiceProxy(spec.pathPrefix, spec.upstreamURL, spec.rewritesLFSBatchActions)
		if err != nil {
			return nil, err
		}
		if proxy != nil {
			proxies = append(proxies, proxy)
		}
	}
	return proxies, nil
}

// Validates that the given path is a valid bare git repository.
// Returns an error if the path doesn't exist, isn't a git repository, or isn't bare.
func ValidateRepository(path string) error {
	repo, err := git.PlainOpen(path)
	if err != nil {
		return fmt.Errorf("invalid git repository at %q: %w", path, err)
	}

	cfg, err := repo.Config()
	if err != nil {
		return fmt.Errorf("failed to read repository config at %q: %w", path, err)
	}

	if !cfg.Core.IsBare {
		return fmt.Errorf("repository at %q is not a bare repository", path)
	}

	return nil
}

// Implements http.Handler to serve Git Smart HTTP requests.
// Adds permissive CORS headers so the repository can be accessed from any origin.
// The DEK and range-related headers let browsers stream encrypted media through
// the decryptd and transcoded routes without a separate CORS proxy in front.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS")
	w.Header().Set(
		"Access-Control-Allow-Headers",
		"Content-Type, Authorization, Git-Protocol, Accept, Range, X-Replycant-DEK",
	)
	w.Header().Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	s.handleAuthenticatedRequest(w, r)
}

// Authenticates client certificates before dispatching requests to Git or LFS handlers.
func (s *Server) handleAuthenticatedRequest(w http.ResponseWriter, r *http.Request) {
	if len(r.TLS.PeerCertificates) == 0 {
		http.Error(w, "Client certificate required", http.StatusUnauthorized)
		return
	}

	username, err := s.auth.Authenticate(r.TLS.PeerCertificates[0])
	if err != nil {
		// Check if this is bootstrap mode (empty repository)
		if errors.Is(err, auth.ErrUnauthorizedBootstrap) {
			// Lock the bootstrap mutex to prevent concurrent bootstrap attempts
			s.bootstrapMu.Lock()
			defer s.bootstrapMu.Unlock()

			// Re-check authentication after acquiring lock (repo might not be empty anymore)
			username, err = s.auth.Authenticate(r.TLS.PeerCertificates[0])
			if err != nil && !errors.Is(err, auth.ErrUnauthorizedBootstrap) {
				log.Printf("Authentication failed after bootstrap lock: %v", err)
				http.Error(w, "Authentication failed", http.StatusUnauthorized)
				return
			}
			// If still in bootstrap mode, proceed with username="bootstrap"
			log.Printf("Bootstrap mode: allowing push to empty repository")
		} else {
			log.Printf("Authentication failed: %v", err)
			http.Error(w, "Authentication failed", http.StatusUnauthorized)
			return
		}
	}

	log.Printf("Authenticated user: %s, path: %s", username, r.URL.Path)

	for _, proxy := range s.serviceProxies {
		if !proxy.matches(r.URL.Path) {
			continue
		}
		if err := s.proxyToService(proxy, w, r); err != nil {
			log.Printf("Error proxying to %s: %v", proxy.pathPrefix, err)
			http.Error(w, "Bad gateway", http.StatusBadGateway)
		}
		return
	}

	if err := s.proxyToGitBackend(w, r, username); err != nil {
		log.Printf("Error proxying to git-http-backend: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}
}

// Invokes git-http-backend as a CGI process to handle the Git protocol.
// This allows gitd to focus on authentication while delegating Git operations to the standard backend.
func (s *Server) proxyToGitBackend(w http.ResponseWriter, r *http.Request, username string) error {
	handler := &cgi.Handler{
		Path: s.gitBackendPath,
		Env: []string{
			fmt.Sprintf("GIT_PROJECT_ROOT=%s", s.repoPath),
			"GIT_HTTP_EXPORT_ALL=1",
			fmt.Sprintf("REMOTE_USER=%s", username),
			fmt.Sprintf("REPLYCANT_LFS_URL=%s", s.lfsURL),
		},
	}

	handler.ServeHTTP(w, r)
	return nil
}

// installPreReceiveHook installs a deterministic pre-receive hook so every push enforces LFS object existence.
func (s *Server) installPreReceiveHook() error {
	hookBinaryPath, err := exec.LookPath("lfs-prereceive")
	if err != nil {
		return fmt.Errorf("lfs-prereceive binary not found: %w", err)
	}

	hooksDir := filepath.Join(s.repoPath, "hooks")
	if err := os.MkdirAll(hooksDir, 0755); err != nil {
		return fmt.Errorf("create hooks directory: %w", err)
	}

	hookPath := filepath.Join(hooksDir, "pre-receive")
	if _, err := os.Lstat(hookPath); err == nil {
		if err := os.Remove(hookPath); err != nil {
			return fmt.Errorf("replace existing pre-receive hook: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect existing pre-receive hook: %w", err)
	}

	if err := os.Symlink(hookBinaryPath, hookPath); err != nil {
		return fmt.Errorf("install pre-receive hook: %w", err)
	}

	return nil
}

// Locates git-http-backend in common installation paths.
// Required to delegate Git protocol handling to the standard CGI backend.
func findGitHttpBackend() (string, error) {
	candidates := []string{
		"/usr/lib/git-core/git-http-backend",
		"/usr/libexec/git-core/git-http-backend",
	}

	for _, path := range candidates {
		if _, err := os.Stat(path); err == nil {
			return path, nil
		}
	}

	// Try finding via git --exec-path
	cmd := exec.Command("git", "--exec-path")
	output, err := cmd.Output()
	if err == nil {
		execPath := strings.TrimSpace(string(output))
		backendPath := filepath.Join(execPath, "git-http-backend")
		if _, err := os.Stat(backendPath); err == nil {
			return backendPath, nil
		}
	}

	return "", fmt.Errorf("git-http-backend not found in common paths")
}
