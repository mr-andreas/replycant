package repo

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"sync"

	"github.com/go-git/go-billy/v5/osfs"
	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/cache"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/storage/filesystem"
	"github.com/mr-andreas/replycant/server/manifest"
)

var author = object.Signature{
	Name:  "Replycant",
	Email: "commit@replycant.com",
}

type Repo struct {
	registry manifest.Registry

	repo *git.Repository
	lock sync.Mutex

	author object.Signature
}

type OperationType int

const (
	// Adds a text file such as a YAML manifest to the repository. The file will
	// be commited as a regular file in git.
	OpTypeAdd OperationType = iota

	OpTypeRemove
)

// Adds or removes a manifest from the database. If a manifest is added with a
// name that already exists, it will be ovewritten. If a non-existing manifest
// is deleted, no error is returned.
type Operation struct {
	Type OperationType

	// Adds a YAML manifest to the repository. The file will be commited as a
	// regular file in git.
	Manifest manifest.Manifest

	// Adds a binary file to the repository. The file will be commited as an LFS
	// object.
	//
	// The path should be relative to the device path.
	//
	// Mutually exclusive with Manifest.
	BinaryPath   string
	BinaryReader func() (io.ReadCloser, error)
}

// Creates a new repository in the specified directory. The directory must not
// exist.
func Init(r *manifest.Registry, dir string) (*Repo, error) {
	gitDir := dir + "/.git"

	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("repo init: dir already exists: %w", err)
	}

	err := os.MkdirAll(gitDir, 0755)
	if err != nil {
		return nil, fmt.Errorf("repo init failed: %w", err)
	}

	fs := filesystem.NewStorage(osfs.New(gitDir), cache.NewObjectLRUDefault())
	gitRepo, gitErr := git.Init(fs, osfs.New(dir))
	if gitErr != nil {
		return nil, fmt.Errorf("repo init: %w", gitErr)
	}

	// Run git lfs install
	cmd := exec.Command("git", "lfs", "install")
	cmd.Dir = dir
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("repo init: %w", err)
	}

	// Treat all files in the binary directory as LFS objects
	cmd2 := exec.Command("git", "lfs", "track", "binary/**")
	cmd2.Dir = dir
	if err := cmd2.Run(); err != nil {
		return nil, fmt.Errorf("repo init: %w", err)
	}

	// Commit the .gitattributes file
	wt, wtErr := gitRepo.Worktree()
	if wtErr != nil {
		return nil, fmt.Errorf("repo init: %w", wtErr)
	}
	if _, err := wt.Add(".gitattributes"); err != nil {
		return nil, fmt.Errorf("repo init: %w", err)
	}
	if _, err := wt.Commit("Replycant init", &git.CommitOptions{
		Author: &author,
	}); err != nil {
		return nil, fmt.Errorf("repo init: %w", err)
	}

	return openWithRepo(r, gitRepo), nil
}

// Creates a commit in the repository.
func (r *Repo) Commit(ops []Operation) error {
	wt, wtErr := r.repo.Worktree()
	if wtErr != nil {
		return fmt.Errorf("commit: %w", wtErr)
	}

	// Clean the worktree in case there are any untracked files left from a
	// previous crashed operation.
	stCmd := exec.Command("git", "clean", "-fd")
	stCmd.Dir = wt.Filesystem.Root()
	if err := stCmd.Run(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	// if err := wt.Clean(&git.CleanOptions{}); err != nil {
	// 	return fmt.Errorf("commit: %w", err)
	// }

	for _, op := range ops {
		switch op.Type {
		case OpTypeAdd:
			if op.Manifest != nil && op.BinaryPath != "" {
				return fmt.Errorf("commit %s: %w", op.BinaryPath, ErrManifestAndBinarySet)
			}

			if op.Manifest == nil && op.BinaryPath == "" {
				return fmt.Errorf("commit: %w", ErrManifestAndBinaryNotSet)
			}

			if op.Manifest != nil {
				if err := r.addFile(wt, op.Manifest); err != nil {
					return err
				}
			} else {
				if err := r.addFileBinary(wt, op.BinaryPath, op.BinaryReader); err != nil {
					return err
				}
			}

		case OpTypeRemove:
			panic("Not implemented")

		default:
			return fmt.Errorf("commit: unknown operation type %v", op.Type)
		}
	}

	// Use the git binary as it has more than 2x the performance
	cmd := exec.Command("git", "add", ".")
	cmd.Dir = wt.Filesystem.Root()
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	// fmt.Println("Glob added")
	// if err := wt.AddGlob("."); err != nil {
	// 	return fmt.Errorf("commit: %w", err)
	// }

	cmd2 := exec.Command(
		"git", "commit", "-m", "commit", "--author",
		fmt.Sprintf("%s <%s>", r.author.Name, r.author.Email),
	)
	cmd2.Dir = wt.Filesystem.Root()
	if err := cmd2.Run(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}

	// _, err := wt.Commit("commit", &git.CommitOptions{
	// 	Author: &r.author,
	// })
	// if err != nil {
	// 	return fmt.Errorf("commit: %w", err)
	// }

	return nil
}

// Loads all manifests in the repo and returns them. The manifests are grouped
// by their package and type name.
func (r *Repo) LoadAllManifests() (map[string][]manifest.Manifest, error) {
	wt, wtErr := r.repo.Worktree()
	if wtErr != nil {
		return nil, fmt.Errorf("load all: %w", wtErr)
	}

	manifests := map[string][]manifest.Manifest{}
	if err := r.loadManifestsRecursively(wt, "", manifests); err != nil {
		return nil, fmt.Errorf("load all: %w", err)
	}

	return manifests, nil
}

func (r *Repo) loadManifestsRecursively(wt *git.Worktree, Path string, out map[string][]manifest.Manifest) error {
	files, fErr := wt.Filesystem.ReadDir(Path)
	if fErr != nil {
		return fmt.Errorf("load all: %w", fErr)
	}

	for _, f := range files {
		if f.IsDir() {
			err := r.loadManifestsRecursively(wt, Path+"/"+f.Name(), out)
			if err != nil {
				return err
			}
			continue
		}

		if path.Ext(f.Name()) == ".yaml" {
			m, ti, err := r.loadFile(wt, Path+"/"+f.Name())
			if err != nil {
				return err
			}

			out[ti.RegisteredName()] = append(out[ti.RegisteredName()], m)
		}
	}

	return nil
}

func (r *Repo) loadFile(wt *git.Worktree, path string) (manifest.Manifest, *manifest.RegisteredType, error) {
	f, fErr := wt.Filesystem.Open(path)
	if fErr != nil {
		return nil, nil, fmt.Errorf("load file %s: %w", path, fErr)
	}
	defer f.Close()

	// path will always start with a leading slash. Remove it, as we don't use
	// that in our package names.
	path = path[1:]

	m, ti, mErr := r.registry.Unmarshal(path, f)
	if mErr != nil {
		return nil, nil, fmt.Errorf("load file %s: %w", path, mErr)
	}

	return m, ti, nil
}

func (r *Repo) addFile(wt *git.Worktree, m manifest.Manifest) error {
	// Convert the manifest to YAML using the registry
	path, yml, err := r.registry.Marshal(m)
	if err != nil {
		return fmt.Errorf("commit %v: %w", m, err)
	}

	f, fErr := wt.Filesystem.Create(path)
	if fErr != nil {
		return fmt.Errorf("commit %v: %w", m, fErr)
	}
	defer f.Close()

	if _, err := f.Write(yml); err != nil {
		return fmt.Errorf("commit %v: %w", m, err)
	}

	if err := f.Close(); err != nil {
		return fmt.Errorf("commit %v: %w", m, err)
	}

	// if _, err := wt.Add(path); err != nil {
	// 	return fmt.Errorf("commit %v: %w", m, err)
	// }

	return nil
}

func (r *Repo) addFileBinary(wt *git.Worktree, path string, rdFunc func() (io.ReadCloser, error)) error {
	rd, err := rdFunc()
	if err != nil {
		return fmt.Errorf("commit %s: %w", path, err)
	}
	defer rd.Close()

	f, fErr := wt.Filesystem.Create("binary/" + path)
	if fErr != nil {
		return fmt.Errorf("commit %s: %w", path, fErr)
	}
	defer f.Close()

	if _, err := io.Copy(f, rd); err != nil {
		return fmt.Errorf("commit %s: %w", path, err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("commit %s: %w", path, err)
	}

	return nil
}

func Open(reg *manifest.Registry, path string) (*Repo, error) {
	r, err := git.PlainOpen(path)
	if err != nil {
		return nil, fmt.Errorf("open: %w", err)
	}

	return openWithRepo(reg, r), nil
}

func openWithRepo(reg *manifest.Registry, r *git.Repository) *Repo {
	repo := &Repo{
		registry: *reg,
		repo:     r,
	}
	repo.author = author

	return repo
}

// Opens a binary file. The path should be relative to the binary directory.
func (r *Repo) OpenBinary(path string) (io.ReadCloser, error) {
	wt, wtErr := r.repo.Worktree()
	if wtErr != nil {
		return nil, fmt.Errorf("open binary %s: %w", path, wtErr)
	}

	f, err := wt.Filesystem.OpenFile("binary/"+path, os.O_RDONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("open binary %s: %w", path, err)
	}
	return f, nil
}
