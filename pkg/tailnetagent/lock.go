package tailnetagent

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// errLockHeld means another live process already owns the file.
//
// flock is released when that process exits, including a crash, which is why
// a leftover agent.json is not treated as proof that an agent is running.
var errLockHeld = errors.New("lock held")

type fileLock struct {
	file *os.File
}

// startLockGrace is how long a new agent waits out a readiness probe.
//
// The probe holds the lock only for the check itself. A lock that stays
// held belongs to another agent, which must still lose.
const startLockGrace = 250 * time.Millisecond

// lockExclusive takes a non-blocking exclusive lock.
//
// Non-blocking so a second agent can exit immediately and let callers keep
// using the one that already joined, instead of queueing behind it.
func lockExclusive(path string) (*fileLock, error) {
	return flock(path, unix.LOCK_EX|unix.LOCK_NB)
}

// lockForStart takes the agent lock, waiting out a brief readiness probe.
//
// Callers learn whether an agent is up by taking this lock for a moment,
// and that overlaps the one instant a new agent takes it. Giving up on the
// first try drops a tailnet join that already succeeded, and the git
// command then waits out the ready timeout.
func lockForStart(path string) (*fileLock, error) {
	deadline := time.Now().Add(startLockGrace)
	for {
		lock, err := lockExclusive(path)
		if err == nil || !errors.Is(err, errLockHeld) {
			return lock, err
		}
		if time.Now().After(deadline) {
			return nil, err
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// lockExclusiveWait blocks until this process can own the file.
//
// Used around spawning so two git commands that both notice a missing agent
// do not start two nodes.
func lockExclusiveWait(path string) (*fileLock, error) {
	return flock(path, unix.LOCK_EX)
}

func flock(path string, how int) (*fileLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open lock %s: %w", path, err)
	}
	if err := unix.Flock(int(file.Fd()), how); err != nil {
		_ = file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, errLockHeld
		}
		return nil, fmt.Errorf("lock %s: %w", path, err)
	}
	return &fileLock{file: file}, nil
}

func (l *fileLock) Close() error {
	if l == nil || l.file == nil {
		return nil
	}
	_ = unix.Flock(int(l.file.Fd()), unix.LOCK_UN)
	err := l.file.Close()
	l.file = nil
	return err
}

// lockHeldByOther reports whether some other process owns path.
//
// Acquiring and releasing the lock ourselves is the check: if it succeeds,
// nobody else had it.
func lockHeldByOther(path string) bool {
	lock, err := lockExclusive(path)
	if err != nil {
		return errors.Is(err, errLockHeld)
	}
	_ = lock.Close()
	return false
}
