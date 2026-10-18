package tailnetagent

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Refuses an unauthenticated CONNECT before anything is dialed on the tailnet.
// The proxy shares a machine with other users, and the credential is the only
// thing that stops them using this repository's node.
func TestConnectRequiresAuth(t *testing.T) {
	var dials atomic.Int32
	_, proxyAddr, _ := startTestAgent(t, func(ctx context.Context, network, addr string) (net.Conn, error) {
		dials.Add(1)
		return nil, errors.New("should not dial")
	})

	conn, err := net.Dial("tcp", proxyAddr)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()
	if _, err := io.WriteString(conn, "CONNECT gitd.replycant.internal:8443 HTTP/1.1\r\nHost: gitd.replycant.internal:8443\r\n\r\n"); err != nil {
		t.Fatalf("write CONNECT: %v", err)
	}
	status := readHTTPStatus(t, conn)
	if status != 407 {
		t.Fatalf("status = %d, want 407", status)
	}
	if dials.Load() != 0 {
		t.Fatalf("unauthenticated CONNECT dialed the tailnet %d times", dials.Load())
	}
}

// An authenticated CONNECT is spliced onto the injected dialer, which is what
// lets tests prove the proxy without bringing up WireGuard.
func TestConnectReachesInjectedDialer(t *testing.T) {
	backend := listenTCP(t)
	defer backend.Close()
	go func() {
		conn, err := backend.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4)
		_, _ = io.ReadFull(conn, buf)
		_, _ = conn.Write([]byte("pong"))
	}()

	_, proxyAddr, password := startTestAgent(t, func(ctx context.Context, network, addr string) (net.Conn, error) {
		if addr != "gitd.replycant.internal:8443" {
			t.Errorf("dialed %q, want gitd.replycant.internal:8443", addr)
		}
		return net.Dial("tcp", backend.Addr().String())
	})

	conn, err := net.Dial("tcp", proxyAddr)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()
	auth := base64.StdEncoding.EncodeToString([]byte(proxyUsername + ":" + password))
	fmt.Fprintf(conn, "CONNECT gitd.replycant.internal:8443 HTTP/1.1\r\nHost: gitd.replycant.internal:8443\r\nProxy-Authorization: Basic %s\r\n\r\n", auth)
	if status := readHTTPStatus(t, conn); status != 200 {
		t.Fatalf("status = %d, want 200", status)
	}
	if _, err := io.WriteString(conn, "ping"); err != nil {
		t.Fatalf("write: %v", err)
	}
	buf := make([]byte, 4)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(buf) != "pong" {
		t.Fatalf("payload = %q", buf)
	}
}

// The agent is a per-repo background process, so it has to leave on its own
// once nothing is using the proxy.
func TestAgentExitsWhenIdle(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- (&Server{
			Dir:         Dir(dir),
			IdleTimeout: 150 * time.Millisecond,
			Password:    "secret",
		}).Run(ctx)
	}()
	waitReady(t, dir)
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("idle agent: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("agent did not exit after going idle")
	}
	if _, err := os.Stat(readyPath(Dir(dir))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("readiness file still present after exit: %v", err)
	}
}

// Two agents on one state directory would split the node identity, so the
// second one has to give up while the first still holds the lock.
func TestSecondAgentExitsWhileLockHeld(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		_ = (&Server{Dir: Dir(dir), IdleTimeout: time.Hour, Password: "secret"}).Run(ctx)
	}()
	waitReady(t, dir)

	err := (&Server{Dir: Dir(dir), IdleTimeout: time.Hour, Password: "other"}).Run(context.Background())
	if !errors.Is(err, ErrAlreadyRunning) {
		t.Fatalf("second agent error = %v, want ErrAlreadyRunning", err)
	}
}

// Callers learn whether an agent is up by taking its lock for a moment.
// That overlaps the instant a new agent takes the same lock. Giving up on
// the first try drops a tailnet join that already succeeded, and the git
// command then waits out the ready timeout.
func TestAgentStartsWhileProbeHoldsLock(t *testing.T) {
	dir := t.TempDir()
	agentDir := Dir(dir)
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatalf("create agent dir: %v", err)
	}
	lock, err := lockExclusive(lockPath(agentDir))
	if err != nil {
		t.Fatalf("take probe lock: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- (&Server{
			Dir:         agentDir,
			IdleTimeout: time.Hour,
			Password:    "secret",
		}).Run(ctx)
	}()

	time.Sleep(20 * time.Millisecond)
	if err := lock.Close(); err != nil {
		t.Fatalf("release probe lock: %v", err)
	}

	select {
	case err := <-done:
		t.Fatalf("agent exited while the probe lock was only briefly held: %v", err)
	case <-time.After(time.Second):
	}
	if _, err := readReady(readyPath(agentDir)); err != nil {
		t.Fatalf("readiness file: %v", err)
	}
}

// The readiness file carries the proxy credential, so it must not be group
// readable, and it must disappear when the agent exits so the next caller
// does not dial a dead port.
func TestReadyFileIsPrivateAndRemoved(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- (&Server{Dir: Dir(dir), IdleTimeout: time.Hour, Password: "secret"}).Run(ctx)
	}()
	waitReady(t, dir)

	info, err := os.Stat(readyPath(Dir(dir)))
	if err != nil {
		t.Fatalf("stat readiness file: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("readiness file mode = %o, want 600", info.Mode().Perm())
	}
	raw, err := os.ReadFile(readyPath(Dir(dir)))
	if err != nil {
		t.Fatalf("read readiness file: %v", err)
	}
	if len(raw) == 0 {
		t.Fatal("readiness file is empty")
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("agent exit: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("agent did not exit after cancel")
	}
	if _, err := os.Stat(readyPath(Dir(dir))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("readiness file still present: %v", err)
	}
}

// Overlapping git commands must start one node between them. A second node
// against the same state directory either fails or registers a duplicate.
func TestEnsureSpawnsOnceWhenCalledConcurrently(t *testing.T) {
	gitDir := t.TempDir()
	var calls atomic.Int32
	var once sync.Once
	spawn := func(cfg StartConfig) error {
		calls.Add(1)
		once.Do(func() {
			go func() {
				_ = (&Server{
					Dir:         Dir(cfg.GitDir),
					IdleTimeout: time.Hour,
					Password:    "secret",
				}).Run(context.Background())
			}()
		})
		return nil
	}

	var wg sync.WaitGroup
	urls := make([]string, 2)
	errs := make([]error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			urls[i], errs[i] = Ensure(context.Background(), gitDir, StartConfig{}, spawn)
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("ensure %d: %v", i, err)
		}
	}
	if urls[0] == "" || urls[0] != urls[1] {
		t.Fatalf("proxy urls = %q %q", urls[0], urls[1])
	}
	if calls.Load() != 1 {
		t.Fatalf("spawn calls = %d, want 1", calls.Load())
	}
}

// A clone that never joined has nothing to dial. Callers surface that as a
// re-clone instruction rather than a timeout against an address that does
// not exist.
func TestLoadConfigMissingIsNotConfigured(t *testing.T) {
	_, err := LoadConfig(t.TempDir())
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("error = %v, want ErrNotConfigured", err)
	}
}

func startTestAgent(t *testing.T, dial DialFunc) (gitDir, proxyAddr, password string) {
	t.Helper()
	gitDir = t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() {
		_ = (&Server{
			Dir:         Dir(gitDir),
			Dial:        dial,
			IdleTimeout: time.Hour,
			Password:    "secret",
		}).Run(ctx)
	}()
	ready := waitReady(t, gitDir)
	parsed, err := url.Parse(ready.ProxyURL)
	if err != nil {
		t.Fatalf("parse proxy URL: %v", err)
	}
	password, _ = parsed.User.Password()
	return gitDir, parsed.Host, password
}

func waitReady(t *testing.T, gitDir string) Ready {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		ready, err := readReady(readyPath(Dir(gitDir)))
		if err == nil {
			return ready
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("agent did not publish a readiness file")
	return Ready{}
}

func listenTCP(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	return ln
}

func readHTTPStatus(t *testing.T, conn net.Conn) int {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	var version string
	var status int
	if _, err := fmt.Sscanf(line, "%s %d", &version, &status); err != nil {
		t.Fatalf("parse status %q: %v", line, err)
	}
	for {
		extra, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read header: %v", err)
		}
		if extra == "\r\n" || extra == "\n" {
			break
		}
	}
	return status
}
