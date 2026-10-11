package tailnetagent

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// Spawner starts an agent that will publish a readiness file.
//
// Tests replace it with an in-process server. The real spawner runs
// git-replycant tailnet-agent so the node outlives the git command that
// needed it.
type Spawner func(cfg StartConfig) error

// Ensure returns the proxy URL for gitDir, starting the agent when it is not
// already up.
//
// spawn may be nil, in which case the detached tailnet-agent subcommand is
// used. cfg is what that process reads on stdin; it carries the device key,
// so it is never placed on the command line.
func Ensure(ctx context.Context, gitDir string, cfg StartConfig, spawn Spawner) (string, error) {
	if url, ok := liveProxy(gitDir); ok {
		return url, nil
	}
	dir := Dir(gitDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create tailnet directory: %w", err)
	}

	spawnLock, err := lockExclusiveWait(spawnLockPath(dir))
	if err != nil {
		return "", err
	}
	defer spawnLock.Close()

	if url, ok := liveProxy(gitDir); ok {
		return url, nil
	}
	// A readiness file without a live lock is a crashed agent. Leaving it
	// would make the next caller dial a port nothing is listening on.
	_ = os.Remove(readyPath(dir))

	if spawn == nil {
		spawn = SpawnDetached
	}
	cfg.GitDir = gitDir
	if err := spawn(cfg); err != nil {
		return "", err
	}

	deadline := time.Now().Add(DefaultReadyTimeout)
	if until, ok := ctx.Deadline(); ok && until.Before(deadline) {
		deadline = until
	}
	for {
		if url, ok := liveProxy(gitDir); ok {
			return url, nil
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("tailnet agent did not become ready: %s", tailLog(dir))
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

// liveProxy is a running agent: the lock is held and the readiness file names
// a proxy URL. Either condition alone is not enough.
func liveProxy(gitDir string) (string, bool) {
	dir := Dir(gitDir)
	if !lockHeldByOther(lockPath(dir)) {
		return "", false
	}
	ready, err := readReady(readyPath(dir))
	if err != nil {
		return "", false
	}
	return ready.ProxyURL, true
}

// ProxyURL returns the proxy of an already-running agent.
func ProxyURL(gitDir string) (string, bool) {
	return liveProxy(gitDir)
}

// SpawnDetached starts tailnet-agent in its own session.
//
// The git command that triggered the start exits when the transfer ends, and
// the agent has to stay up for the next command and for the pre-push hook
// that runs beside the transport.
func SpawnDetached(cfg StartConfig) error {
	raw, err := encodeStartConfig(cfg)
	if err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("find git-replycant to start the tailnet agent: %w", err)
	}
	logFile, err := os.OpenFile(logPath(Dir(cfg.GitDir)), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("open tailnet agent log: %w", err)
	}
	cmd := exec.Command(exe, "tailnet-agent")
	cmd.Stdin = bytes.NewReader(raw)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return fmt.Errorf("start tailnet agent: %w", err)
	}
	// The child has inherited the log fd. Closing the parent's copy does not
	// close the child's.
	_ = logFile.Close()
	return nil
}

func tailLog(dir string) string {
	raw, err := os.ReadFile(logPath(dir))
	if err != nil || len(raw) == 0 {
		return "no agent log"
	}
	if len(raw) > 2000 {
		raw = raw[len(raw)-2000:]
	}
	return string(raw)
}
