package migrate

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/require"
)

// TestChainedStepsCommitOnce checks that every step from the stored
// version to the target runs in order and lands in a single commit.
// Clients must never observe an intermediate format.
func TestChainedStepsCommitOnce(t *testing.T) {
	t.Parallel()
	repo, dir := initRepo(t)
	seed := commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version":  "1\n",
		"notes/keep.txt": "keep",
	})
	var seen []int
	steps := []Step{
		{From: 1, Apply: func(tree *Tree) error {
			seen = append(seen, 1)
			return tree.Write("step-1", []byte("one"))
		}},
		{From: 2, Apply: func(tree *Tree) error {
			seen = append(seen, 2)
			raw, err := tree.Read(gitcrypt.DatabaseVersionPath)
			if err != nil {
				return err
			}
			if string(raw) != "1\n" {
				return errors.New("version was written before the last step")
			}
			return tree.Write("step-2", []byte("two"))
		}},
	}

	result, err := run(dir, steps, 3, runConfig{})
	require.NoError(t, err)
	require.Equal(t, Result{Migrated: true, From: 1, To: 3}, result)
	require.Equal(t, []int{1, 2}, seen)

	head := headCommit(t, dir)
	require.NotEqual(t, seed, head.Hash)
	require.Equal(t, []plumbing.Hash{seed}, head.ParentHashes)
	require.Equal(t, "Migrate gitdb from version 1 to 3\n", head.Message)
	require.Equal(t, "gitd", head.Author.Name)
	require.Equal(t, "gitd@localhost", head.Author.Email)
	require.Equal(t, "3\n", readBlob(t, dir, "gitdb/version"))
	require.Equal(t, "one", readBlob(t, dir, "step-1"))
	require.Equal(t, "two", readBlob(t, dir, "step-2"))
	require.Equal(t, "keep", readBlob(t, dir, "notes/keep.txt"))
	require.Equal(t, 2, commitCount(t, dir))
}

// TestMigrationLogsVersionsBeforeRewriting tells an operator that a
// boot is about to rewrite the library, and which formats are involved,
// before any step runs. The completion line comes only after the commit.
func TestMigrationLogsVersionsBeforeRewriting(t *testing.T) {
	t.Parallel()
	repo, dir := initRepo(t)
	commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version": "1\n",
	})
	var lines []string
	logged := false
	steps := []Step{{From: 1, Apply: func(*Tree) error {
		if !logged {
			return errors.New("rewrite started before the migration was logged")
		}
		return nil
	}}}

	_, err := run(dir, steps, 2, runConfig{
		logf: func(format string, args ...any) {
			lines = append(lines, fmt.Sprintf(format, args...))
			logged = true
		},
	})
	require.NoError(t, err)
	require.Equal(t, []string{"Migrating gitdb from version 1 to 2"}, lines)
}

// TestCurrentVersionDoesNothing keeps a restarted gitd from adding an
// empty commit every time it boots.
func TestCurrentVersionDoesNothing(t *testing.T) {
	t.Parallel()
	repo, dir := initRepo(t)
	seed := commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version": "2\n",
	})
	steps := []Step{{From: 1, Apply: func(*Tree) error {
		return errors.New("should not run")
	}}}

	result, err := run(dir, steps, 2, runConfig{})
	require.NoError(t, err)
	require.False(t, result.Migrated)
	require.Equal(t, seed, headCommit(t, dir).Hash)
}

// TestEmptyRepositoryDoesNothing lets a first-device bootstrap create
// main itself. There is no marker to migrate yet.
func TestEmptyRepositoryDoesNothing(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	_, err := git.PlainInitWithOptions(dir, &git.PlainInitOptions{
		Bare:        true,
		InitOptions: git.InitOptions{DefaultBranch: plumbing.Main},
	})
	require.NoError(t, err)

	result, err := run(dir, productionSteps, gitcrypt.DatabaseFormatVersion, runConfig{})
	require.NoError(t, err)
	require.False(t, result.Migrated)
	_, hash := openMain(t, dir)
	require.Equal(t, plumbing.ZeroHash, hash)
}

// TestMissingMalformedOrNewerMarkerDoesNotMoveMain refuses to guess.
// A library without a marker, or one this binary does not understand,
// must stay exactly as it was so an operator can recover it.
func TestMissingMalformedOrNewerMarkerDoesNotMoveMain(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name  string
		files map[string]string
		want  string
	}{
		{name: "missing", files: map[string]string{"notes/keep.txt": "keep"}, want: "missing"},
		{name: "malformed", files: map[string]string{"gitdb/version": "nope\n"}, want: "invalid"},
		{name: "newer", files: map[string]string{"gitdb/version": "9\n"}, want: "newer"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			repo, dir := initRepo(t)
			seed := commitFiles(t, repo, dir, "seed", tc.files)
			_, err := run(dir, productionSteps, gitcrypt.DatabaseFormatVersion, runConfig{})
			require.ErrorContains(t, err, tc.want)
			require.Equal(t, seed, headCommit(t, dir).Hash)
		})
	}
}

// TestFailingStepLeavesMainUntouched rolls the whole migration back
// when one step refuses. A half-applied tree must not become main.
func TestFailingStepLeavesMainUntouched(t *testing.T) {
	t.Parallel()
	repo, dir := initRepo(t)
	seed := commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version": "1\n",
	})
	steps := []Step{{From: 1, Apply: func(tree *Tree) error {
		if err := tree.Write("partial", []byte("x")); err != nil {
			return err
		}
		return errors.New("boom")
	}}}

	_, err := run(dir, steps, 2, runConfig{})
	require.ErrorContains(t, err, "boom")
	require.Equal(t, seed, headCommit(t, dir).Hash)
	require.Equal(t, "1\n", readBlob(t, dir, "gitdb/version"))
}

// TestLostCompareAndSwapDoesNotPublishMigration aborts when main moves
// after the commit object is written. The raced push stays on main.
func TestLostCompareAndSwapDoesNotPublishMigration(t *testing.T) {
	t.Parallel()
	repo, dir := initRepo(t)
	seed := commitFiles(t, repo, dir, "seed", map[string]string{
		"gitdb/version": "1\n",
	})
	cfg := runConfig{beforeAdvance: func(open *git.Repository) error {
		work, err := open.Worktree()
		if err != nil {
			return err
		}
		path := filepath.Join(dir, "raced.txt")
		if err := os.WriteFile(path, []byte("raced"), 0o644); err != nil {
			return err
		}
		if _, err := work.Add("raced.txt"); err != nil {
			return err
		}
		_, err = work.Commit("race", &git.CommitOptions{
			Author: &object.Signature{Name: "Test", Email: "test@example.com", When: time.Unix(1_700_000_100, 0)},
		})
		return err
	}}

	_, err := run(dir, []Step{{From: 1, Apply: func(*Tree) error { return nil }}}, 2, cfg)
	require.ErrorContains(t, err, "reference has changed")
	head := headCommit(t, dir)
	require.NotEqual(t, seed, head.Hash)
	require.Equal(t, "race", head.Message)
	require.Equal(t, "1\n", readBlob(t, dir, "gitdb/version"))
	require.Equal(t, "raced", readBlob(t, dir, "raced.txt"))
	require.Equal(t, 2, commitCount(t, dir))
}

// TestSubmoduleAborts refuses a tree gitd cannot rewrite as plaintext
// files. Dropping a submodule would silently change the library.
func TestSubmoduleAborts(t *testing.T) {
	t.Parallel()
	repo, dir := initRepo(t)
	tree := &object.Tree{Entries: []object.TreeEntry{{
		Name: "vendor",
		Mode: filemode.Submodule,
		Hash: plumbing.NewHash("0123456789abcdef0123456789abcdef01234567"),
	}}}
	obj := repo.Storer.NewEncodedObject()
	require.NoError(t, tree.Encode(obj))
	treeHash, err := repo.Storer.SetEncodedObject(obj)
	require.NoError(t, err)
	commit := &object.Commit{
		Author:    object.Signature{Name: "Test", Email: "test@example.com", When: time.Unix(1_700_000_000, 0)},
		Committer: object.Signature{Name: "Test", Email: "test@example.com", When: time.Unix(1_700_000_000, 0)},
		Message:   "sub\n",
		TreeHash:  treeHash,
	}
	encoded := repo.Storer.NewEncodedObject()
	require.NoError(t, commit.Encode(encoded))
	hash, err := repo.Storer.SetEncodedObject(encoded)
	require.NoError(t, err)
	require.NoError(t, repo.Storer.SetReference(plumbing.NewHashReference(plumbing.Main, hash)))

	_, err = run(dir, productionSteps, gitcrypt.DatabaseFormatVersion, runConfig{})
	require.ErrorContains(t, err, "submodule")
	require.Equal(t, hash, headCommit(t, dir).Hash)
}

// TestProductionStepsAreContiguous keeps a future version bump from
// shipping a binary that cannot walk every integer up to its pin.
func TestProductionStepsAreContiguous(t *testing.T) {
	t.Parallel()
	require.NotEmpty(t, productionSteps)
	for i, step := range productionSteps {
		require.Equal(t, i+1, step.From)
		require.NotNil(t, step.Apply)
	}
	last := productionSteps[len(productionSteps)-1]
	require.Equal(t, gitcrypt.DatabaseFormatVersion, last.From+1)
}

// TestBranchOtherThanMainIsAnError refuses to migrate a repository
// whose history is not the branch gitd serves.
func TestBranchOtherThanMainIsAnError(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	repo, err := git.PlainInitWithOptions(dir, &git.PlainInitOptions{
		InitOptions: git.InitOptions{DefaultBranch: plumbing.Master},
	})
	require.NoError(t, err)
	commitFiles(t, repo, dir, "seed", map[string]string{"gitdb/version": "1\n"})

	_, err = run(dir, productionSteps, gitcrypt.DatabaseFormatVersion, runConfig{})
	require.ErrorContains(t, err, "refs/heads/main is missing")
}

func initRepo(t *testing.T) (*git.Repository, string) {
	t.Helper()
	dir := t.TempDir()
	repo, err := git.PlainInitWithOptions(dir, &git.PlainInitOptions{
		InitOptions: git.InitOptions{DefaultBranch: plumbing.Main},
	})
	require.NoError(t, err)
	return repo, dir
}

func commitFiles(t *testing.T, repo *git.Repository, dir string, message string, files map[string]string) plumbing.Hash {
	t.Helper()
	work, err := repo.Worktree()
	require.NoError(t, err)
	for path, content := range files {
		full := filepath.Join(dir, filepath.FromSlash(path))
		require.NoError(t, os.MkdirAll(filepath.Dir(full), 0o755))
		require.NoError(t, os.WriteFile(full, []byte(content), 0o644))
		_, err = work.Add(path)
		require.NoError(t, err)
	}
	hash, err := work.Commit(message, &git.CommitOptions{
		Author: &object.Signature{Name: "Test", Email: "test@example.com", When: time.Unix(1_700_000_000, 0)},
	})
	require.NoError(t, err)
	return hash
}

func headCommit(t *testing.T, dir string) *object.Commit {
	t.Helper()
	repo, hash := openMain(t, dir)
	commit, err := repo.CommitObject(hash)
	require.NoError(t, err)
	return commit
}

func openMain(t *testing.T, dir string) (*git.Repository, plumbing.Hash) {
	t.Helper()
	repo, err := git.PlainOpen(dir)
	require.NoError(t, err)
	ref, err := repo.Reference(plumbing.Main, true)
	if err != nil {
		return repo, plumbing.ZeroHash
	}
	return repo, ref.Hash()
}

func readBlob(t *testing.T, dir string, path string) string {
	t.Helper()
	commit := headCommit(t, dir)
	file, err := commit.File(path)
	require.NoError(t, err)
	text, err := file.Contents()
	require.NoError(t, err)
	return text
}

func commitCount(t *testing.T, dir string) int {
	t.Helper()
	repo, hash := openMain(t, dir)
	require.NotEqual(t, plumbing.ZeroHash, hash)
	count := 0
	iter, err := repo.Log(&git.LogOptions{From: hash})
	require.NoError(t, err)
	defer iter.Close()
	err = iter.ForEach(func(*object.Commit) error {
		count++
		return nil
	})
	require.NoError(t, err)
	return count
}
