package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/mdns"
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

// lfsUploadObject describes one object that may need uploading to the LFS server.
type lfsUploadObject struct {
	OID  string `json:"oid"`
	Size int64  `json:"size"`
}

// lfsBatchRequest models the minimal request shape needed for upload batch negotiation.
type lfsBatchRequest struct {
	Operation string              `json:"operation"`
	Transfers []string            `json:"transfers,omitempty"`
	Ref       *lfsBatchRequestRef `json:"ref,omitempty"`
	Objects   []lfsUploadObject   `json:"objects"`
}

// lfsBatchRequestRef carries remote ref context so ref-aware servers can authorize upload.
type lfsBatchRequestRef struct {
	Name string `json:"name"`
}

// lfsBatchResponse models object actions returned by the LFS batch upload API.
type lfsBatchResponse struct {
	Transfer string           `json:"transfer"`
	Objects  []lfsBatchObject `json:"objects"`
	Message  string           `json:"message"`
}

// lfsBatchObject holds per-object transfer actions or an object-specific error.
type lfsBatchObject struct {
	OID     string                    `json:"oid"`
	Size    int64                     `json:"size"`
	Actions map[string]lfsBatchAction `json:"actions"`
	Error   *lfsBatchError            `json:"error"`
}

// lfsBatchAction points to one follow-up HTTP call (upload or verify) plus optional headers.
type lfsBatchAction struct {
	Href   string            `json:"href"`
	Header map[string]string `json:"header"`
}

// lfsBatchError carries object-level error data from the batch endpoint.
type lfsBatchError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// lfsEndpoint stores LFS base URL and optional basic auth derived from lfs.url config.
type lfsEndpoint struct {
	BaseURL    *url.URL
	AuthHeader string
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
	client, err := buildLFSHTTPClient(".")
	if err != nil {
		return err
	}
	if err := uploadMissingLFSObjects(client, ".", endpoint, refName, objects); err != nil {
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
func collectUpdatedLFSObjects(repoDir string, remoteName string, updates []prePushRefUpdate) ([]lfsUploadObject, string, error) {
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

	objects := make([]lfsUploadObject, 0, len(objectByOID))
	for oid, size := range objectByOID {
		objects = append(objects, lfsUploadObject{OID: oid, Size: size})
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
func resolveLFSEndpoint(repoDir string) (lfsEndpoint, error) {
	rawURL, err := RunGitOutput(context.Background(), repoDir, "config", "--get", "lfs.url")
	if err != nil {
		return lfsEndpoint{}, fmt.Errorf("failed to resolve lfs.url: %w", err)
	}
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return lfsEndpoint{}, fmt.Errorf("invalid lfs.url %q: %w", strings.TrimSpace(rawURL), err)
	}
	if strings.TrimSpace(parsed.Scheme) == "" || strings.TrimSpace(parsed.Host) == "" {
		return lfsEndpoint{}, fmt.Errorf("invalid lfs.url %q", strings.TrimSpace(rawURL))
	}
	authHeader := ""
	if parsed.User != nil {
		username := parsed.User.Username()
		password, _ := parsed.User.Password()
		token := base64.StdEncoding.EncodeToString([]byte(username + ":" + password))
		authHeader = "Basic " + token
		parsed.User = nil
	}
	return lfsEndpoint{BaseURL: parsed, AuthHeader: authHeader}, nil
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

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, fmt.Errorf("failed loading mTLS client certificate: %w", err)
	}
	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("failed reading CA file %q: %w", caPath, err)
	}
	rootCAs := x509.NewCertPool()
	if ok := rootCAs.AppendCertsFromPEM(caPEM); !ok {
		return nil, fmt.Errorf("failed parsing CA certificate bundle at %q", caPath)
	}

	return &http.Client{
		Transport: &http.Transport{
			DialContext: mdns.DialContext,
			TLSClientConfig: &tls.Config{
				MinVersion:   tls.VersionTLS13,
				RootCAs:      rootCAs,
				Certificates: []tls.Certificate{cert},
			},
		},
	}, nil
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

// uploadMissingLFSObjects negotiates upload actions then sends local object bytes for missing OIDs only.
func uploadMissingLFSObjects(
	client *http.Client,
	repoDir string,
	endpoint lfsEndpoint,
	refName string,
	objects []lfsUploadObject,
) error {
	if len(objects) == 0 {
		return nil
	}
	parsed, err := sendLFSBatchRequest(client, endpoint, refName, objects)
	if err != nil {
		return err
	}
	expected := map[string]lfsUploadObject{}
	for _, object := range objects {
		expected[object.OID] = object
	}
	gitDir, err := resolveGitDir(repoDir)
	if err != nil {
		return err
	}
	for _, object := range parsed.Objects {
		expectedObject, ok := expected[object.OID]
		if !ok {
			continue
		}
		if err := processLFSBatchObject(client, gitDir, endpoint, expectedObject, object); err != nil {
			return err
		}
	}
	return nil
}

// sendLFSBatchRequest builds and sends an LFS batch upload request, returning the parsed server response
// so the caller can decide per-object what to upload.
func sendLFSBatchRequest(
	client *http.Client,
	endpoint lfsEndpoint,
	refName string,
	objects []lfsUploadObject,
) (*lfsBatchResponse, error) {
	batchURL := *endpoint.BaseURL
	batchURL.Path = strings.TrimSuffix(batchURL.Path, "/") + "/objects/batch"
	batchURL.RawQuery = ""
	batchURL.Fragment = ""
	fmt.Fprintf(
		os.Stderr,
		"git-replycant pre-push: batch_request endpoint=%s objects=%d ref=%q\n",
		batchURL.String(),
		len(objects),
		strings.TrimSpace(refName),
	)

	reqPayload := lfsBatchRequest{
		Operation: "upload",
		Transfers: []string{"basic"},
		Objects:   objects,
	}
	if strings.TrimSpace(refName) != "" {
		reqPayload.Ref = &lfsBatchRequestRef{Name: refName}
	}
	body, err := json.Marshal(reqPayload)
	if err != nil {
		return nil, fmt.Errorf("failed encoding lfs batch request: %w", err)
	}
	req, err := http.NewRequest(http.MethodPost, batchURL.String(), bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("failed creating lfs batch request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.git-lfs+json")
	req.Header.Set("Content-Type", "application/vnd.git-lfs+json")
	if endpoint.AuthHeader != "" {
		req.Header.Set("Authorization", endpoint.AuthHeader)
	}
	ctxTimeout, cancel := context.WithTimeout(context.Background(), 600*time.Second)
	defer cancel()
	req = req.WithContext(ctxTimeout)
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("lfs batch request failed: %w", err)
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed reading lfs batch response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("lfs batch request failed with status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	fmt.Fprintf(os.Stderr, "git-replycant pre-push: batch_response status=%d\n", resp.StatusCode)

	var parsed lfsBatchResponse
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return nil, fmt.Errorf("failed decoding lfs batch response: %w", err)
	}
	fmt.Fprintf(
		os.Stderr,
		"git-replycant pre-push: batch_objects=%d transfer=%q\n",
		len(parsed.Objects),
		strings.TrimSpace(parsed.Transfer),
	)
	return &parsed, nil
}

// processLFSBatchObject handles one object from the batch response: uploads when the server requests it,
// falls back to HEAD+direct-upload when batch omits the upload action, and verifies when requested.
func processLFSBatchObject(
	client *http.Client,
	gitDir string,
	endpoint lfsEndpoint,
	expectedObject lfsUploadObject,
	batchObject lfsBatchObject,
) error {
	if batchObject.Error != nil {
		return fmt.Errorf("lfs object %s failed with code %d: %s", batchObject.OID, batchObject.Error.Code, strings.TrimSpace(batchObject.Error.Message))
	}
	uploadAction, hasUpload := batchObject.Actions["upload"]
	if !hasUpload {
		// Temporary compatibility fallback for lfs-test-server: batch can report an object as present
		// via metadata while object bytes are still missing. Remove this HEAD+direct-upload path once
		// Replycant runs its own LFS server that guarantees accurate object existence in batch responses.
		exists, err := headCheckObjectExists(client, endpoint, batchObject.OID)
		if err != nil {
			return err
		}
		if exists {
			fmt.Fprintf(os.Stderr, "git-replycant pre-push: object %s verified present via HEAD; skipping upload\n", batchObject.OID)
			return nil
		}
		fmt.Fprintf(
			os.Stderr,
			"git-replycant pre-push: object %s batch-reported present but missing via HEAD; uploading directly\n",
			batchObject.OID,
		)
		directAction := lfsBatchAction{
			Href: buildObjectURL(endpoint, batchObject.OID),
			Header: map[string]string{
				"Accept": "application/vnd.git-lfs",
			},
		}
		if err := uploadOneLFSObject(client, gitDir, endpoint, expectedObject, directAction); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "git-replycant pre-push: uploaded oid=%s via direct fallback\n", expectedObject.OID)
		return nil
	}
	fmt.Fprintf(os.Stderr, "git-replycant pre-push: uploading oid=%s size=%d\n", expectedObject.OID, expectedObject.Size)
	if err := uploadOneLFSObject(client, gitDir, endpoint, expectedObject, uploadAction); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "git-replycant pre-push: uploaded oid=%s\n", expectedObject.OID)
	if verifyAction, hasVerify := batchObject.Actions["verify"]; hasVerify {
		fmt.Fprintf(os.Stderr, "git-replycant pre-push: verifying oid=%s\n", expectedObject.OID)
		if err := verifyOneLFSObject(client, endpoint, expectedObject, verifyAction); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "git-replycant pre-push: verified oid=%s\n", expectedObject.OID)
	}
	return nil
}

// uploadOneLFSObject streams one local .git/lfs object to the upload action URL returned by batch.
func uploadOneLFSObject(
	client *http.Client,
	gitDir string,
	endpoint lfsEndpoint,
	object lfsUploadObject,
	action lfsBatchAction,
) error {
	objectPath := filepath.Join(gitDir, "lfs", "objects", object.OID[0:2], object.OID[2:4], object.OID)
	file, err := os.Open(objectPath)
	if err != nil {
		return fmt.Errorf("failed opening local lfs object %s: %w", object.OID, err)
	}
	defer file.Close()
	req, err := http.NewRequest(http.MethodPut, action.Href, file)
	if err != nil {
		return fmt.Errorf("failed creating upload request for %s: %w", object.OID, err)
	}
	req.ContentLength = object.Size
	applyActionHeaders(req, action.Header)
	if endpoint.AuthHeader != "" && req.Header.Get("Authorization") == "" {
		req.Header.Set("Authorization", endpoint.AuthHeader)
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed uploading lfs object %s: %w", object.OID, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed uploading lfs object %s: status %d: %s", object.OID, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

// verifyOneLFSObject confirms uploaded objects when the server returns a verify action.
func verifyOneLFSObject(
	client *http.Client,
	endpoint lfsEndpoint,
	object lfsUploadObject,
	action lfsBatchAction,
) error {
	payload, err := json.Marshal(lfsUploadObject{OID: object.OID, Size: object.Size})
	if err != nil {
		return fmt.Errorf("failed encoding verify request for %s: %w", object.OID, err)
	}
	req, err := http.NewRequest(http.MethodPost, action.Href, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("failed creating verify request for %s: %w", object.OID, err)
	}
	req.Header.Set("Accept", "application/vnd.git-lfs+json")
	req.Header.Set("Content-Type", "application/vnd.git-lfs+json")
	applyActionHeaders(req, action.Header)
	if endpoint.AuthHeader != "" && req.Header.Get("Authorization") == "" {
		req.Header.Set("Authorization", endpoint.AuthHeader)
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed verifying lfs object %s: %w", object.OID, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed verifying lfs object %s: status %d: %s", object.OID, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

// applyActionHeaders propagates server-provided request headers for upload/verify actions.
func applyActionHeaders(req *http.Request, headers map[string]string) {
	for key, value := range headers {
		if strings.TrimSpace(key) == "" {
			continue
		}
		req.Header.Set(key, value)
	}
}

// isZeroGitObjectID normalizes sha strings before comparing with all-zero sentinel IDs.
func isZeroGitObjectID(value string) bool {
	return strings.TrimSpace(value) == zeroGitObjectID
}

// headCheckObjectExists verifies object content presence at /objects/{oid}.
func headCheckObjectExists(client *http.Client, endpoint lfsEndpoint, oid string) (bool, error) {
	req, err := http.NewRequest(http.MethodHead, buildObjectURL(endpoint, oid), nil)
	if err != nil {
		return false, fmt.Errorf("failed creating head request for %s: %w", oid, err)
	}
	req.Header.Set("Accept", "application/vnd.git-lfs")
	if endpoint.AuthHeader != "" {
		req.Header.Set("Authorization", endpoint.AuthHeader)
	}
	resp, err := client.Do(req)
	if err != nil {
		return false, fmt.Errorf("failed checking lfs object %s via head: %w", oid, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1))
	return resp.StatusCode >= 200 && resp.StatusCode < 300, nil
}

// buildObjectURL creates the direct /objects/{oid} endpoint URL.
func buildObjectURL(endpoint lfsEndpoint, oid string) string {
	objectURL := *endpoint.BaseURL
	objectURL.Path = strings.TrimSuffix(objectURL.Path, "/") + "/objects/" + oid
	objectURL.RawQuery = ""
	objectURL.Fragment = ""
	return objectURL.String()
}

// summarizeObjectOIDs renders a compact OID list to keep pre-push diagnostics readable.
func summarizeObjectOIDs(objects []lfsUploadObject) string {
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
