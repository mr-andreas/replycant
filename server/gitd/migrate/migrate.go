// Package migrate updates a library's plaintext layout before gitd
// serves it. Steps never see the KEK, so they can only rewrite data
// that is already stored in the clear. Each boot applies every step
// from the on-disk gitdb/version up to this binary's pin, then
// publishes one commit. Clients therefore never fetch a half-migrated
// tree, and a crash before the ref moves leaves main unchanged.
package migrate

import (
	"errors"
	"fmt"
	"io"
	"log"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"
	"github.com/mr-andreas/replycant/pkg/gitcrypt"
)

const mainRef = plumbing.Main

// Step upgrades a library from From to From+1. Apply sees the tree
// produced by the previous step and must not touch git itself.
type Step struct {
	From  int
	Apply func(*Tree) error
}

// Result reports whether this boot published a migration commit.
type Result struct {
	Migrated bool
	From     int
	To       int
}

// Tree is the in-memory view of main. Steps change only this view;
// the runner writes it back in one commit after every step succeeds.
type Tree struct {
	files map[string]blob
}

type blob struct {
	mode filemode.FileMode
	data []byte
}

// runConfig.beforeAdvance runs after the migration commit object
// exists and before main moves. Tests use it to land a competing
// push in that window. logf records the start of a rewrite; tests
// capture it, and Run sends it to the process log.
type runConfig struct {
	beforeAdvance func(*git.Repository) error
	logf          func(string, ...any)
}

// Run brings the repository at repoPath up to this binary's database
// format. An empty repository is left alone so the first device can
// create main. Any other failure is returned so gitd can exit before
// it listens.
func Run(repoPath string) (Result, error) {
	return run(repoPath, productionSteps, gitcrypt.DatabaseFormatVersion, runConfig{
		logf: log.Printf,
	})
}

func run(repoPath string, steps []Step, target int, cfg runConfig) (Result, error) {
	repo, err := git.PlainOpen(repoPath)
	if err != nil {
		return Result{}, fmt.Errorf("open repository: %w", err)
	}
	ref, err := repo.Reference(mainRef, true)
	if err != nil {
		if errors.Is(err, plumbing.ErrReferenceNotFound) {
			hasBranch, branchErr := repositoryHasBranch(repo)
			if branchErr != nil {
				return Result{}, branchErr
			}
			if !hasBranch {
				return Result{}, nil
			}
			return Result{}, fmt.Errorf("%s is missing", mainRef)
		}
		return Result{}, fmt.Errorf("read %s: %w", mainRef, err)
	}

	tree, err := loadTree(repo, ref.Hash())
	if err != nil {
		return Result{}, err
	}
	raw, err := tree.Read(gitcrypt.DatabaseVersionPath)
	if err != nil {
		return Result{}, fmt.Errorf("%s is missing", gitcrypt.DatabaseVersionPath)
	}
	version, err := gitcrypt.ParseDatabaseVersion(raw)
	if err != nil {
		return Result{}, err
	}
	if version > target {
		return Result{}, fmt.Errorf("gitdb/version %d is newer than this server supports (%d)", version, target)
	}
	if version == target {
		return Result{From: version, To: version}, nil
	}

	from := version
	// The rewrite can fail or take long enough that the later
	// "migrated" line never appears. Say which versions are in
	// play before the first step changes the tree.
	if cfg.logf != nil {
		cfg.logf("Migrating gitdb from version %d to %d", from, target)
	}
	for version < target {
		step, ok := stepFrom(steps, version)
		if !ok {
			return Result{}, fmt.Errorf("no migration step from version %d", version)
		}
		if err := step.Apply(tree); err != nil {
			return Result{}, fmt.Errorf("migrate gitdb from version %d: %w", version, err)
		}
		version++
	}
	if err := tree.Write(gitcrypt.DatabaseVersionPath, []byte(fmt.Sprintf("%d\n", target))); err != nil {
		return Result{}, err
	}

	newHash, err := writeCommit(repo, ref.Hash(), tree, from, target)
	if err != nil {
		return Result{}, err
	}
	if cfg.beforeAdvance != nil {
		if err := cfg.beforeAdvance(repo); err != nil {
			return Result{}, err
		}
	}
	newRef := plumbing.NewHashReference(mainRef, newHash)
	oldRef := plumbing.NewHashReference(mainRef, ref.Hash())
	if err := repo.Storer.CheckAndSetReference(newRef, oldRef); err != nil {
		return Result{}, fmt.Errorf("advance %s: %w", mainRef, err)
	}
	return Result{Migrated: true, From: from, To: target}, nil
}

func stepFrom(steps []Step, version int) (Step, bool) {
	for _, step := range steps {
		if step.From == version {
			return step, true
		}
	}
	return Step{}, false
}

// List returns every file path with the given prefix, in sorted order.
// The prefix is a literal path prefix, so "pubkeys/" does not match a
// sibling file named "pubkeys-old".
func (t *Tree) List(prefix string) []string {
	paths := make([]string, 0, len(t.files))
	for filePath := range t.files {
		if prefix == "" || strings.HasPrefix(filePath, prefix) {
			paths = append(paths, filePath)
		}
	}
	sort.Strings(paths)
	return paths
}

// Read returns a copy of one file. The copy keeps a step from mutating
// the stored bytes through the returned slice.
func (t *Tree) Read(filePath string) ([]byte, error) {
	file, ok := t.files[filePath]
	if !ok {
		return nil, fmt.Errorf("%s is missing", filePath)
	}
	return append([]byte(nil), file.data...), nil
}

// Write replaces one plaintext file. New files are regular blobs;
// gitd has no reason to invent executables or symlinks.
func (t *Tree) Write(filePath string, data []byte) error {
	clean, err := cleanPath(filePath)
	if err != nil {
		return err
	}
	if t.files == nil {
		t.files = map[string]blob{}
	}
	mode := filemode.Regular
	if existing, ok := t.files[clean]; ok {
		mode = existing.mode
	}
	t.files[clean] = blob{mode: mode, data: append([]byte(nil), data...)}
	return nil
}

// Delete removes a file the step has replaced. A missing path is not
// an error: the step is stating the path must not survive.
func (t *Tree) Delete(filePath string) {
	delete(t.files, filePath)
}

func cleanPath(filePath string) (string, error) {
	if filePath == "" || strings.HasPrefix(filePath, "/") || strings.Contains(filePath, "\\") {
		return "", fmt.Errorf("invalid path %q", filePath)
	}
	if filePath != path.Clean(filePath) || strings.HasPrefix(filePath, "../") || filePath == ".." {
		return "", fmt.Errorf("invalid path %q", filePath)
	}
	return filePath, nil
}

func repositoryHasBranch(repo *git.Repository) (bool, error) {
	iter, err := repo.Branches()
	if err != nil {
		return false, fmt.Errorf("list branches: %w", err)
	}
	defer iter.Close()
	_, err = iter.Next()
	if errors.Is(err, io.EOF) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("list branches: %w", err)
	}
	return true, nil
}

func loadTree(repo *git.Repository, commitHash plumbing.Hash) (*Tree, error) {
	commit, err := repo.CommitObject(commitHash)
	if err != nil {
		return nil, fmt.Errorf("read commit: %w", err)
	}
	root, err := commit.Tree()
	if err != nil {
		return nil, fmt.Errorf("read tree: %w", err)
	}
	files := map[string]blob{}
	if err := collectTree(root, "", files); err != nil {
		return nil, err
	}
	return &Tree{files: files}, nil
}

func collectTree(tree *object.Tree, prefix string, files map[string]blob) error {
	for _, entry := range tree.Entries {
		filePath := entry.Name
		if prefix != "" {
			filePath = prefix + "/" + entry.Name
		}
		switch entry.Mode {
		case filemode.Dir:
			sub, err := tree.Tree(entry.Name)
			if err != nil {
				return fmt.Errorf("read %s: %w", filePath, err)
			}
			if err := collectTree(sub, filePath, files); err != nil {
				return err
			}
		case filemode.Submodule:
			return fmt.Errorf("submodule %s is not plaintext data", filePath)
		case filemode.Regular, filemode.Executable, filemode.Symlink:
			file, err := tree.File(entry.Name)
			if err != nil {
				return fmt.Errorf("read %s: %w", filePath, err)
			}
			reader, err := file.Reader()
			if err != nil {
				return fmt.Errorf("read %s: %w", filePath, err)
			}
			data, err := io.ReadAll(reader)
			reader.Close()
			if err != nil {
				return fmt.Errorf("read %s: %w", filePath, err)
			}
			files[filePath] = blob{mode: entry.Mode, data: data}
		default:
			return fmt.Errorf("unsupported mode %s for %s", entry.Mode, filePath)
		}
	}
	return nil
}

func writeCommit(repo *git.Repository, parent plumbing.Hash, tree *Tree, from int, to int) (plumbing.Hash, error) {
	treeHash, err := storeTree(repo.Storer, tree)
	if err != nil {
		return plumbing.ZeroHash, err
	}
	when := time.Now().UTC()
	signature := object.Signature{Name: "gitd", Email: "gitd@localhost", When: when}
	commit := &object.Commit{
		Author:       signature,
		Committer:    signature,
		Message:      fmt.Sprintf("Migrate gitdb from version %d to %d\n", from, to),
		TreeHash:     treeHash,
		ParentHashes: []plumbing.Hash{parent},
	}
	encoded := repo.Storer.NewEncodedObject()
	if err := commit.Encode(encoded); err != nil {
		return plumbing.ZeroHash, fmt.Errorf("encode commit: %w", err)
	}
	hash, err := repo.Storer.SetEncodedObject(encoded)
	if err != nil {
		return plumbing.ZeroHash, fmt.Errorf("write commit: %w", err)
	}
	return hash, nil
}

func storeTree(st storer.EncodedObjectStorer, tree *Tree) (plumbing.Hash, error) {
	root := &treeNode{files: map[string]blob{}, dirs: map[string]*treeNode{}}
	for filePath, file := range tree.files {
		parts := strings.Split(filePath, "/")
		node := root
		for _, dir := range parts[:len(parts)-1] {
			node = node.child(dir)
		}
		node.files[parts[len(parts)-1]] = file
	}
	return root.store(st)
}

type treeNode struct {
	files map[string]blob
	dirs  map[string]*treeNode
}

func (n *treeNode) child(name string) *treeNode {
	if n.dirs[name] == nil {
		n.dirs[name] = &treeNode{files: map[string]blob{}, dirs: map[string]*treeNode{}}
	}
	return n.dirs[name]
}

func (n *treeNode) store(st storer.EncodedObjectStorer) (plumbing.Hash, error) {
	entries := make([]object.TreeEntry, 0, len(n.files)+len(n.dirs))
	for name, file := range n.files {
		hash, err := storeBlob(st, file.data)
		if err != nil {
			return plumbing.ZeroHash, err
		}
		entries = append(entries, object.TreeEntry{Name: name, Mode: file.mode, Hash: hash})
	}
	for name, dir := range n.dirs {
		hash, err := dir.store(st)
		if err != nil {
			return plumbing.ZeroHash, err
		}
		entries = append(entries, object.TreeEntry{Name: name, Mode: filemode.Dir, Hash: hash})
	}
	sort.Sort(object.TreeEntrySorter(entries))
	encoded := st.NewEncodedObject()
	if err := (&object.Tree{Entries: entries}).Encode(encoded); err != nil {
		return plumbing.ZeroHash, fmt.Errorf("encode tree: %w", err)
	}
	hash, err := st.SetEncodedObject(encoded)
	if err != nil {
		return plumbing.ZeroHash, fmt.Errorf("write tree: %w", err)
	}
	return hash, nil
}

func storeBlob(st storer.EncodedObjectStorer, data []byte) (plumbing.Hash, error) {
	encoded := st.NewEncodedObject()
	encoded.SetType(plumbing.BlobObject)
	encoded.SetSize(int64(len(data)))
	writer, err := encoded.Writer()
	if err != nil {
		return plumbing.ZeroHash, err
	}
	if _, err := writer.Write(data); err != nil {
		writer.Close()
		return plumbing.ZeroHash, err
	}
	if err := writer.Close(); err != nil {
		return plumbing.ZeroHash, err
	}
	hash, err := st.SetEncodedObject(encoded)
	if err != nil {
		return plumbing.ZeroHash, fmt.Errorf("write blob: %w", err)
	}
	return hash, nil
}
