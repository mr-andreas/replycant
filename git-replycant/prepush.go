package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/lfsclient"
)

const (
	// zeroGitObjectID identifies ref updates where one side is missing (new ref or deletion).
	zeroGitObjectID = "0000000000000000000000000000000000000000"
)

// prePushRefUpdate captures one pre-push stdin line describing local/remote ref tips.
type prePushRefUpdate struct {
	LocalRef  string
	LocalSHA  string
	RemoteRef string
	RemoteSHA string
}

// RunPrePush discovers pushed Replycant pointers and uploads missing encrypted object payloads.
func RunPrePush(remoteName string, remoteURL string, stdin io.Reader) error {
	fmt.Fprintf(os.Stderr, "git-replycant pre-push: start remote=%q url=%q\n", strings.TrimSpace(remoteName), strings.TrimSpace(remoteURL))
	updates, err := parsePrePushUpdates(stdin)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "git-replycant pre-push: parsed_updates=%d\n", len(updates))
	if len(updates) == 0 {
		fmt.Fprintln(os.Stderr, "git-replycant pre-push: no ref updates, nothing to upload")
		return nil
	}
	objects, refName, err := collectUpdatedLFSObjects(".", remoteName, updates)
	if err != nil {
		return err
	}
	fmt.Fprintf(
		os.Stderr,
		"git-replycant pre-push: discovered_objects=%d ref=%q oids=%s\n",
		len(objects),
		strings.TrimSpace(refName),
		summarizeObjectOIDs(objects),
	)
	if len(objects) == 0 {
		fmt.Fprintln(os.Stderr, "git-replycant pre-push: no Replycant LFS objects found in pushed commits")
		return nil
	}
	endpoint, err := resolveLFSEndpoint(".")
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "git-replycant pre-push: lfs_endpoint=%s\n", endpoint.BaseURL.String())
	httpClient, err := buildLFSHTTPClient(".")
	if err != nil {
		return err
	}
	gitDir, err := resolveGitDir(".")
	if err != nil {
		return err
	}
	client := &lfsclient.Client{
		HTTP:     httpClient,
		Endpoint: endpoint,
		Log:      os.Stderr,
	}
	if err := client.Upload(context.Background(), refName, objects, openLocalLFSObject(gitDir)); err != nil {
		fmt.Fprintf(os.Stderr, "git-replycant pre-push: failed: %v\n", err)
		return err
	}
	fmt.Fprintf(os.Stderr, "git-replycant pre-push: completed uploaded_or_verified=%d\n", len(objects))
	return nil
}

// parsePrePushUpdates reads all ref updates from git's pre-push hook stdin format.
func parsePrePushUpdates(input io.Reader) ([]prePushRefUpdate, error) {
	updates := []prePushRefUpdate{}
	scanner := bufio.NewScanner(input)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 4 {
			return nil, fmt.Errorf("invalid pre-push update line %q", line)
		}
		updates = append(updates, prePushRefUpdate{
			LocalRef:  fields[0],
			LocalSHA:  fields[1],
			RemoteRef: fields[2],
			RemoteSHA: fields[3],
		})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("failed reading pre-push updates: %w", err)
	}
	return updates, nil
}

// collectUpdatedLFSObjects resolves newly pushed commits then extracts unique pointer OID/size pairs.
// remoteName is the git remote (or URL) passed to the pre-push hook and is used to bound the
// commit scan against remote-tracking refs when the advertised remote tip is not present locally.
func collectUpdatedLFSObjects(repoDir string, remoteName string, updates []prePushRefUpdate) ([]lfsclient.Object, string, error) {
	commitSet := map[string]struct{}{}
	refName := ""
	for _, update := range updates {
		if refName == "" && strings.TrimSpace(update.RemoteRef) != "" && !isZeroGitObjectID(update.LocalSHA) {
			refName = strings.TrimSpace(update.RemoteRef)
		}
		commits, err := listNewCommitOIDs(repoDir, remoteName, update)
		if err != nil {
			return nil, "", err
		}
		for _, commit := range commits {
			commitSet[commit] = struct{}{}
		}
	}
	if len(commitSet) == 0 {
		return nil, refName, nil
	}

	commits := make([]string, 0, len(commitSet))
	for commit := range commitSet {
		commits = append(commits, commit)
	}
	sort.Strings(commits)

	objectByOID := map[string]int64{}
	for _, commit := range commits {
		paths, err := listChangedBinaryPathsForCommit(repoDir, commit)
		if err != nil {
			return nil, "", err
		}
		for _, path := range paths {
			pointer, hasPointer, err := readPointerAtCommitPath(repoDir, commit, path)
			if err != nil {
				return nil, "", err
			}
			if !hasPointer {
				continue
			}
			if existingSize, exists := objectByOID[pointer.OID]; exists && existingSize != pointer.Size {
				return nil, "", fmt.Errorf("conflicting pointer size for oid %s: %d vs %d", pointer.OID, existingSize, pointer.Size)
			}
			objectByOID[pointer.OID] = pointer.Size
		}
	}

	objects := make([]lfsclient.Object, 0, len(objectByOID))
	for oid, size := range objectByOID {
		objects = append(objects, lfsclient.Object{OID: oid, Size: size})
	}
	sort.Slice(objects, func(i, j int) bool { return objects[i].OID < objects[j].OID })
	return objects, refName, nil
}

// listNewCommitOIDs returns commits reachable from local tip and not yet on the remote tip.
// When the advertised remote tip is missing locally (common under concurrent pushers), it
// falls back to excluding remote-tracking refs so LFS uploads still proceed.
func listNewCommitOIDs(repoDir string, remoteName string, update prePushRefUpdate) ([]string, error) {
	if isZeroGitObjectID(update.LocalSHA) {
		return nil, nil
	}
	args := []string{"rev-list", strings.TrimSpace(update.LocalSHA)}
	if !isZeroGitObjectID(update.RemoteSHA) {
		remoteSHA := strings.TrimSpace(update.RemoteSHA)
		if commitObjectExists(repoDir, remoteSHA) {
			args = append(args, "^"+remoteSHA)
		} else {
			fmt.Fprintf(
				os.Stderr,
				"git-replycant pre-push: remote tip %s not present locally; scanning against remote-tracking refs\n",
				remoteSHA,
			)
			args = append(args, "--not", remoteTrackingExcludeArg(repoDir, remoteName))
		}
	}
	out, err := RunGitOutput(context.Background(), repoDir, args...)
	if err != nil {
		return nil, fmt.Errorf("failed listing commits for %s: %w", update.LocalRef, err)
	}
	commits := []string{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			commits = append(commits, trimmed)
		}
	}
	return commits, nil
}

// commitObjectExists reports whether sha resolves to a local commit object.
func commitObjectExists(repoDir string, sha string) bool {
	_, err := RunGitOutput(context.Background(), repoDir, "cat-file", "-e", sha+"^{commit}")
	return err == nil
}

// remoteTrackingExcludeArg chooses the rev-list --not bound for an unknown remote tip.
// Named remotes use --remotes=<name>; bare push URLs fall back to all remote-tracking refs.
func remoteTrackingExcludeArg(repoDir string, remoteName string) string {
	name := strings.TrimSpace(remoteName)
	if name == "" {
		return "--remotes"
	}
	_, err := RunGitOutput(context.Background(), repoDir, "config", "--get", "remote."+name+".url")
	if err != nil {
		return "--remotes"
	}
	return "--remotes=" + name
}

// listChangedBinaryPathsForCommit lists binary paths added/modified/renamed in one commit.
func listChangedBinaryPathsForCommit(repoDir string, commitOID string) ([]string, error) {
	out, err := RunGitOutput(
		context.Background(),
		repoDir,
		"diff-tree",
		"--root",
		"--no-commit-id",
		"--diff-filter=AMR",
		"--name-only",
		"-r",
		commitOID,
		"--",
		"binary/",
	)
	if err != nil {
		return nil, fmt.Errorf("failed listing binary paths for commit %s: %w", commitOID, err)
	}
	paths := []string{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			paths = append(paths, trimmed)
		}
	}
	return paths, nil
}

// readPointerAtCommitPath reads one blob at commit:path and parses it when it is a Replycant LFS pointer.
func readPointerAtCommitPath(repoDir string, commitOID string, path string) (gitcrypt.LFSPointer, bool, error) {
	blob, err := RunGitOutput(context.Background(), repoDir, "cat-file", "-p", commitOID+":"+path)
	if err != nil {
		return gitcrypt.LFSPointer{}, false, fmt.Errorf("failed reading %s at %s: %w", path, commitOID, err)
	}
	raw := []byte(blob)
	if !gitcrypt.IsLFSPointer(raw) {
		return gitcrypt.LFSPointer{}, false, nil
	}
	pointer, err := gitcrypt.ParseLFSPointer(raw)
	if err != nil {
		return gitcrypt.LFSPointer{}, false, fmt.Errorf("failed parsing pointer %s at %s: %w", path, commitOID, err)
	}
	return pointer, true, nil
}

// resolveLFSEndpoint reads lfs.url config and derives request auth headers when credentials are embedded.
func resolveLFSEndpoint(repoDir string) (lfsclient.Endpoint, error) {
	rawURL, err := RunGitOutput(context.Background(), repoDir, "config", "--get", "lfs.url")
	if err != nil {
		return lfsclient.Endpoint{}, fmt.Errorf("failed to resolve lfs.url: %w", err)
	}
	endpoint, err := lfsclient.ParseEndpoint(strings.TrimSpace(rawURL))
	if err != nil {
		return lfsclient.Endpoint{}, fmt.Errorf("invalid lfs.url: %w", err)
	}
	return endpoint, nil
}

// buildLFSHTTPClient reuses repository mTLS identity config so LFS uploads authenticate the same as Git requests.
func buildLFSHTTPClient(repoDir string) (*http.Client, error) {
	caPath, err := gitConfigValue(repoDir, "http.sslCAInfo")
	if err != nil {
		return nil, err
	}
	certPath, err := gitConfigValue(repoDir, "http.sslCert")
	if err != nil {
		return nil, err
	}
	keyPath, err := gitConfigValue(repoDir, "http.sslKey")
	if err != nil {
		return nil, err
	}
	return lfsclient.NewMTLSHTTPClient(caPath, certPath, keyPath)
}

// gitConfigValue reads one local git config key and fails fast when clone bootstrap omitted required mTLS settings.
func gitConfigValue(repoDir string, key string) (string, error) {
	raw, err := RunGitOutput(context.Background(), repoDir, "config", "--local", "--get", key)
	if err != nil {
		return "", fmt.Errorf("failed to read git config %q: %w", key, err)
	}
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", fmt.Errorf("missing git config %q", key)
	}
	return value, nil
}

// openLocalLFSObject returns an opener that reads objects from the standard git-lfs object layout.
func openLocalLFSObject(gitDir string) lfsclient.OpenFunc {
	return func(object lfsclient.Object) (io.ReadCloser, error) {
		objectPath := filepath.Join(gitDir, "lfs", "objects", object.OID[0:2], object.OID[2:4], object.OID)
		return os.Open(objectPath)
	}
}

// isZeroGitObjectID normalizes sha strings before comparing with all-zero sentinel IDs.
func isZeroGitObjectID(value string) bool {
	return strings.TrimSpace(value) == zeroGitObjectID
}

// summarizeObjectOIDs renders a compact OID list to keep pre-push diagnostics readable.
func summarizeObjectOIDs(objects []lfsclient.Object) string {
	const maxList = 10
	if len(objects) == 0 {
		return ""
	}
	oids := make([]string, 0, len(objects))
	for i, object := range objects {
		if i >= maxList {
			oids = append(oids, fmt.Sprintf("...+%d more", len(objects)-maxList))
			break
		}
		oids = append(oids, object.OID)
	}
	return strings.Join(oids, ",")
}
