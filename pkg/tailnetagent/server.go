package tailnetagent

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

const (
	// DefaultIdle is how long the agent stays up after the last proxied
	// connection. Long enough that a fetch followed by a push reuses the
	// node, short enough that a forgotten agent is not a standing listener.
	DefaultIdle = 5 * time.Minute

	// DefaultReadyTimeout bounds how long callers wait for a freshly spawned
	// agent. Joining the tailnet crosses the hosted relay, so this matches
	// the join budget used by the desktop sidecar.
	DefaultReadyTimeout = 2 * time.Minute
)

// ErrAlreadyRunning means another agent holds this repository's node.
//
// Callers reuse that agent instead of starting a second tsnet against the
// same state directory, which would fail or split the node identity.
var ErrAlreadyRunning = errors.New("tailnet agent is already running for this repository")

// ErrNotConfigured means this clone never joined a tailnet.
//
// Direct connections are not a fallback. The user has to clone again with
// git-replycant so the repository learns where its headscale is.
var ErrNotConfigured = errors.New("this repository has no tailnet configuration; re-clone it with git-replycant")

// Ready is what callers read to dial the proxy. The credential is in the URL
// so git's http.proxy and git-lfs's HTTPS_PROXY can both consume it.
type Ready struct {
	ProxyURL string `json:"proxy_url"`
	PID      int    `json:"pid"`
}

// Server is one repository's proxy lifetime: the lock, the readiness file,
// and the idle exit.
type Server struct {
	// Dir is Dir(gitDir). Required.
	Dir string

	Dial        DialFunc
	IdleTimeout time.Duration

	// Password overrides the generated credential. Tests pin it so they can
	// build the matching Authorization header.
	Password string
}

// Run serves the proxy until the context is cancelled or the proxy goes idle.
//
// The readiness file exists only while this call is in progress. A crash
// drops the lock, and the next caller treats a leftover file as stale.
func (s *Server) Run(ctx context.Context) error {
	if s.Dir == "" {
		return errors.New("tailnet agent directory is required")
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return fmt.Errorf("create tailnet directory: %w", err)
	}

	lock, err := lockExclusive(lockPath(s.Dir))
	if err != nil {
		if errors.Is(err, errLockHeld) {
			return ErrAlreadyRunning
		}
		return err
	}
	defer lock.Close()

	password := s.Password
	if password == "" {
		password, err = randomToken()
		if err != nil {
			return err
		}
	}
	proxy := &Proxy{Dial: s.Dial, Username: proxyUsername, Password: password}
	proxy.touch()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("listen for the tailnet proxy: %w", err)
	}

	ready := Ready{ProxyURL: proxyURL(listener.Addr().String(), password), PID: os.Getpid()}
	if err := writeReady(readyPath(s.Dir), ready); err != nil {
		_ = listener.Close()
		return err
	}
	defer os.Remove(readyPath(s.Dir))

	httpServer := &http.Server{Handler: proxy.handler()}
	serveErr := make(chan error, 1)
	go func() {
		err := httpServer.Serve(listener)
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
			return
		}
		serveErr <- nil
	}()
	defer httpServer.Close()

	idle := s.IdleTimeout
	if idle <= 0 {
		idle = DefaultIdle
	}
	tick := idle / 5
	if tick < 20*time.Millisecond {
		tick = 20 * time.Millisecond
	}
	if tick > time.Second {
		tick = time.Second
	}
	ticker := time.NewTicker(tick)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-serveErr:
			return err
		case now := <-ticker.C:
			if proxy.idle(now) >= idle {
				return nil
			}
		}
	}
}

func proxyURL(addr, password string) string {
	return "http://" + proxyUsername + ":" + password + "@" + addr
}

func randomToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate proxy credential: %w", err)
	}
	return hex.EncodeToString(buf), nil
}

func writeReady(path string, ready Ready) error {
	raw, err := json.Marshal(ready)
	if err != nil {
		return fmt.Errorf("encode tailnet agent address: %w", err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return fmt.Errorf("write tailnet agent address: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("publish tailnet agent address: %w", err)
	}
	return nil
}

func readReady(path string) (Ready, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Ready{}, err
	}
	var ready Ready
	if err := json.Unmarshal(raw, &ready); err != nil {
		return Ready{}, fmt.Errorf("decode tailnet agent address: %w", err)
	}
	if ready.ProxyURL == "" {
		return Ready{}, errors.New("tailnet agent address is missing proxy_url")
	}
	return ready, nil
}
