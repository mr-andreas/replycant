// Stores binary media files - images and videos.
package media

import (
	"crypto/sha256"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"

	"github.com/google/uuid"
	"github.com/mr-andreas/replycant/server/repo"
)

// Describes an image or video in its original form. This is a file such as a
// JPEG, HEIC, mp4 etc.
type Original struct {
	// Unique identifier for the media. It's original will be stored in
	// binary/media/{ID}
	ID uuid.UUID

	// Hash sum of the media
	SHA256 string

	// Absolute path the media resided at when uploaded such as
	// "/home/user/myimages/summer 2024/hiking.jpg". Note that this records the
	// uploader's local directory layout, so it is only safe because manifests
	// are encrypted before they reach the server.
	Path string

	// Size of the media in bytes
	Filesize int64
}

func (o *Original) ManifestID() string {
	return o.ID.String()
}

// Recursively adds all files in a directory to the repository. Files already
// added to the repository (as identified by their path, size and mtime) will
// not be added again.
func RecursiveAdd(path string, r *repo.Repo) error {
	originals, err := recursiveLoadManifests(path, r)
	if err != nil {
		return err
	}

	m, mErr := loadExistingManifests(r)
	if mErr != nil {
		return mErr
	}

	var ops []repo.Operation

	for _, original := range originals {
		// Check if the file is already in the repository
		if existing, ok := m[original.Path]; ok {
			if existing.Filesize == original.Filesize && existing.SHA256 == original.SHA256 {
				continue
			}
		}

		ops = append(ops, repo.Operation{
			Type:     repo.OpTypeAdd,
			Manifest: &original,
		})

		ops = append(ops, repo.Operation{
			Type:       repo.OpTypeAdd,
			BinaryPath: "media/" + shardName(original.ID.String()),
			BinaryReader: func() (io.ReadCloser, error) {
				return os.Open(original.Path)
			},
		})
	}

	if len(ops) > 0 {
		if err := r.Commit(ops); err != nil {
			return fmt.Errorf("failed to commit operations: %w", err)
		}
	}

	return nil
}

// shardName keeps binary fanout bounded so one media update does not rewrite huge git trees.
func shardName(name string) string {
	if len(name) < 5 {
		return name
	}
	return name[:2] + "/" + name[2:4] + "/" + name[4:]
}

// Loads all existing manifests from the repository. The key is the Path from
// each Original.
func loadExistingManifests(r *repo.Repo) (map[string]Original, error) {
	manifests, err := r.LoadAllManifests()
	if err != nil {
		return nil, fmt.Errorf("failed to load all manifests: %w", err)
	}

	ret := make(map[string]Original)
	for _, original := range manifests["github.com/mr-andreas/replycant/server/media/Original"] {
		ret[original.(*Original).Path] = *original.(*Original)
	}

	return ret, nil
}

func recursiveLoadManifests(path string, r *repo.Repo) ([]Original, error) {
	// Recursively add all files in path
	entries, err := os.ReadDir(path)
	if err != nil {
		return nil, fmt.Errorf("failed to add directory %s: %w", path, err)
	}

	var ret []Original
	for _, entry := range entries {
		if entry.IsDir() {
			originals, err := recursiveLoadManifests(path+"/"+entry.Name(), r)
			if err != nil {
				return nil, err
			}
			ret = append(ret, originals...)
		} else {
			if !isSupportedFiletype(entry) {
				continue
			}

			original, err := manifestFromPath(path + "/" + entry.Name())
			if err != nil {
				return nil, err
			}
			ret = append(ret, *original)
		}
	}

	return ret, nil
}

// Returns wether the file is a supported media type
func isSupportedFiletype(de fs.DirEntry) bool {
	switch strings.ToLower(path.Ext(de.Name())) {
	case ".jpg", ".jpeg", ".png", ".heic", ".heif":
		return true
	}

	return false
}

func manifestFromPath(path string) (*Original, error) {
	// Get file info
	fi, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("failed to get file info for %s: %w", path, err)
	}

	// Get hash sum
	hash, err := sha256Sum(path)
	if err != nil {
		return nil, fmt.Errorf("failed to get hash sum for %s: %w", path, err)
	}

	return &Original{
		ID:       uuid.New(),
		SHA256:   hash,
		Path:     absPath(path),
		Filesize: fi.Size(),
	}, nil
}

// Returns the absolute path to a file, relative to the current working
// directory.
func absPath(_path string) string {
	cwd, err := os.Getwd()
	if err != nil {
		panic(err)
	}

	return path.Clean(cwd + "/" + _path)
}

func sha256Sum(path string) (string, error) {
	// Open file
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("failed to open file %s: %w", path, err)
	}
	defer f.Close()

	// Create hash
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("failed to copy file to hash sum: %w", err)
	}

	return fmt.Sprintf("%x", h.Sum(nil)), nil
}
