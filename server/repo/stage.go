package repo

import (
	"github.com/go-git/go-git/v5"
	"github.com/mr-andreas/replycant/server/manifest"
)

// Allows files to be staged in git and then commited.
type Stage struct {
	wt     *git.Worktree
	locked bool

	// Releases the lock of the Repo that this stage belongs to.
	unlock func()
}

// Adds a manifest. If a manifest already exists with the same package and ID,
// it will be overwritten.
func (s *Stage) Add(m manifest.Manifest) error {
	panic("Not implemented")
}

// Aborts this staging session and resets the git repository.
func (s *Stage) Abort() error {
	panic("Not implemented")
}

// Creates a git commit from this staging session.
func (s *Stage) Commit() error {
	panic("Not implemented")
}

// Closes this staging session and unlocks the repository.
func (s *Stage) Close() {
	s.unlock()
	s.locked = false
}
