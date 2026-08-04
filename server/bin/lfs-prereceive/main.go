package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"

	"github.com/mr-andreas/replycant/server/gitd/lfs"
)

const zeroHash = "0000000000000000000000000000000000000000"

// RefUpdate represents one pre-receive update line so validation can inspect all pushed refs.
type RefUpdate struct {
	OldHash string
	NewHash string
	RefName string
}

var gitRunner = runGit
var containerLog = newContainerLogger()

// newContainerLogger routes operational hook logs to the container log stream.
// Pre-receive hooks normally write to stderr, but Git intercepts that stream and
// forwards it back to the pushing client as "remote:" lines. Writing to
// /proc/1/fd/2 instead targets the container init process stderr, which Docker
// captures for `docker compose logs`.
//
// If the process is running outside a container and /proc/1/fd/2 is unavailable,
// the logger falls back to io.Discard so hook telemetry does not leak into the
// client-facing rejection channel.
func newContainerLogger() *log.Logger {
	writer, err := os.OpenFile("/proc/1/fd/2", os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return log.New(io.Discard, "", 0)
	}

	return log.New(writer, "lfs-prereceive: ", log.LstdFlags)
}

// run executes pre-receive validation and returns an error that should reject the push when non-nil.
func run() error {
	lfsURL := strings.TrimSpace(os.Getenv("REPLYCANT_LFS_URL"))
	if lfsURL == "" {
		containerLog.Printf("lfs url not configured; skipping validation")
		return nil
	}

	updates, err := readUpdates(os.Stdin)
	if err != nil {
		containerLog.Printf("failed to parse pre-receive updates: %v", err)
		return err
	}
	if len(updates) == 0 {
		containerLog.Printf("received no ref updates; skipping validation")
		return nil
	}
	refNames := make([]string, 0, len(updates))
	for _, update := range updates {
		refNames = append(refNames, update.RefName)
	}
	containerLog.Printf("starting validation for refs=%q using lfs_url=%q", refNames, lfsURL)

	newCommitHashes, err := collectIntroducedCommits(updates)
	if err != nil {
		containerLog.Printf("failed to collect introduced commits: %v", err)
		return err
	}
	if len(newCommitHashes) == 0 {
		containerLog.Printf("no new commits introduced by push")
		return nil
	}
	containerLog.Printf("scanning %d new commits for lfs pointers", len(newCommitHashes))

	objects, err := collectLFSObjects(newCommitHashes)
	if err != nil {
		containerLog.Printf("failed to collect lfs pointers: %v", err)
		return err
	}
	containerLog.Printf("found %d unique lfs pointer objects", len(objects))
	if len(objects) == 0 {
		containerLog.Printf("validation passed because no lfs pointers were introduced")
		return nil
	}

	missing, err := lfs.VerifyObjects(lfsURL, objects)
	if err != nil {
		containerLog.Printf("lfs verification request failed: %v", err)
		return fmt.Errorf("verify lfs objects: %w", err)
	}
	if len(missing) == 0 {
		containerLog.Printf("verified all %d lfs objects successfully", len(objects))
		return nil
	}
	containerLog.Printf("rejecting push because %d lfs objects are missing: %s", len(missing), strings.Join(missing, ", "))

	var b strings.Builder
	b.WriteString("push rejected: missing LFS objects on the LFS server:\n")
	for _, oid := range missing {
		b.WriteString(" - ")
		b.WriteString(oid)
		b.WriteByte('\n')
	}
	return errors.New(strings.TrimSpace(b.String()))
}

// main is the process entrypoint required by Git hook execution semantics.
func main() {
	if err := run(); err != nil {
		containerLog.Printf("push rejected: %v", err)
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
	containerLog.Printf("push accepted")
}

// readUpdates parses pre-receive stdin lines into typed ref updates.
func readUpdates(stdin *os.File) ([]RefUpdate, error) {
	scanner := bufio.NewScanner(stdin)
	updates := []RefUpdate{}

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		parts := strings.Fields(line)
		if len(parts) != 3 {
			return nil, fmt.Errorf("invalid pre-receive update line: %q", line)
		}

		updates = append(updates, RefUpdate{
			OldHash: parts[0],
			NewHash: parts[1],
			RefName: parts[2],
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read pre-receive updates: %w", err)
	}

	return updates, nil
}

// collectIntroducedCommits uses rev-list against current refs to isolate commits introduced by this push.
func collectIntroducedCommits(updates []RefUpdate) ([]string, error) {
	seen := map[string]struct{}{}
	hashes := []string{}

	for _, update := range updates {
		if update.NewHash == zeroHash {
			continue
		}

		output, err := gitRunner("rev-list", update.NewHash, "--not", "--all")
		if err != nil {
			return nil, fmt.Errorf("collect commits for %s (%s): %w", update.RefName, update.NewHash, err)
		}

		for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
			candidate := strings.TrimSpace(line)
			if candidate == "" {
				continue
			}
			if _, exists := seen[candidate]; exists {
				continue
			}
			seen[candidate] = struct{}{}
			hashes = append(hashes, candidate)
		}
	}

	return hashes, nil
}

// parseDiffTreeBlobs parses `git diff-tree --root --no-commit-id -r -z` output and returns unique new blob hashes.
func parseDiffTreeBlobs(output []byte) ([]string, error) {
	records := bytes.Split(output, []byte{0})
	seen := map[string]struct{}{}
	hashes := make([]string, 0)

	for i := 0; i < len(records); {
		record := string(records[i])
		if record == "" {
			i++
			continue
		}
		if !strings.HasPrefix(record, ":") {
			return nil, fmt.Errorf("invalid diff-tree record %q", record)
		}

		meta := strings.Fields(record)
		if len(meta) != 5 {
			return nil, fmt.Errorf("invalid diff-tree metadata %q", record)
		}

		status := meta[4]
		if status == "" {
			return nil, fmt.Errorf("invalid diff-tree status %q", record)
		}

		pathEntries := 1
		switch status[0] {
		case 'C', 'R':
			pathEntries = 2
		}

		if i+pathEntries >= len(records) {
			return nil, fmt.Errorf("truncated diff-tree record %q", record)
		}

		newHash := meta[3]
		if strings.Trim(newHash, "0") != "" {
			if _, exists := seen[newHash]; !exists {
				seen[newHash] = struct{}{}
				hashes = append(hashes, newHash)
			}
		}

		i += 1 + pathEntries
	}

	return hashes, nil
}

// collectLFSObjects scans new commits for pointer blobs so every referenced object can be verified.
func collectLFSObjects(commitHashes []string) ([]lfs.Object, error) {
	seenBlob := map[string]struct{}{}
	objectsByOID := map[string]lfs.Object{}

	for _, commitHash := range commitHashes {
		output, err := gitRunner("diff-tree", "--root", "--no-commit-id", "-r", "-z", commitHash)
		if err != nil {
			return nil, fmt.Errorf("diff tree for commit %s: %w", commitHash, err)
		}

		blobs, err := parseDiffTreeBlobs(output)
		if err != nil {
			return nil, fmt.Errorf("parse diff for commit %s: %w", commitHash, err)
		}

		for _, blobHash := range blobs {
			if _, alreadySeen := seenBlob[blobHash]; alreadySeen {
				continue
			}
			seenBlob[blobHash] = struct{}{}

			sizeOutput, err := gitRunner("cat-file", "-s", blobHash)
			if err != nil {
				return nil, fmt.Errorf("read blob size %s from commit %s: %w", blobHash, commitHash, err)
			}
			size, err := strconv.ParseInt(strings.TrimSpace(string(sizeOutput)), 10, 64)
			if err != nil {
				return nil, fmt.Errorf("parse blob size %s from commit %s: %w", blobHash, commitHash, err)
			}
			if size > 1024 {
				continue
			}

			content, err := gitRunner("cat-file", "blob", blobHash)
			if err != nil {
				return nil, fmt.Errorf("read blob %s from commit %s: %w", blobHash, commitHash, err)
			}
			oid, size, ok := lfs.ParsePointer(string(content))
			if !ok {
				continue
			}

			objectsByOID[oid] = lfs.Object{
				OID:  oid,
				Size: size,
			}
		}
	}

	objects := make([]lfs.Object, 0, len(objectsByOID))
	for _, obj := range objectsByOID {
		objects = append(objects, obj)
	}
	sort.Slice(objects, func(i, j int) bool {
		return objects[i].OID < objects[j].OID
	})
	return objects, nil
}

// runGit executes git commands in hook context so quarantine object visibility matches hook semantics.
func runGit(args ...string) ([]byte, error) {
	cmd := exec.Command("git", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("git %s failed: %w (output: %s)", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return output, nil
}
