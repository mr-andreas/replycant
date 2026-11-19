package main

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
)

// FilterRuntime holds cached crypto state so one process can handle many files efficiently.
type FilterRuntime struct {
	repoRoot            string
	identity            gitcrypt.Identity
	kekCache            map[kekCacheKey][]byte
	spaceModes          map[string]bool
	spaceModesLoaded    bool
	indexHashCache      map[string][32]byte
	indexEncryptedCache map[string][]byte
	lfsProcess          *gitcrypt.LFSFilterProcess
	lfsExtraEnv         []string
	lfsEnvReady         bool
}

// RunSmudgeOnce handles one-shot smudge mode for manual use and debugging.
// Path-argument mode is git textconv, which feeds already-smudged plaintext from
// the worktree for display only — pass that through so `git diff` keeps working.
// Stdin mode carries a real git blob and must reject plaintext.
func RunSmudgeOnce(args []string) error {
	input, err := readFilterInput(args)
	if err != nil {
		return err
	}
	if len(args) == 1 && !gitcrypt.IsEncryptedManifest(input) && !gitcrypt.IsLFSPointer(input) {
		_, err := os.Stdout.Write(input)
		return err
	}
	runtime, err := NewFilterRuntime()
	if err != nil {
		return err
	}
	pathname := ""
	if len(args) == 1 {
		pathname = filepath.ToSlash(args[0])
	}
	var output []byte
	if gitcrypt.IsLFSPointer(input) {
		output, err = runtime.SmudgeLFS(pathname, input, true)
	} else {
		output, err = runtime.Smudge(pathname, input)
	}
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(output)
	return err
}

// RunCleanOnce handles one-shot clean mode for manual use and debugging.
func RunCleanOnce(args []string) error {
	input, err := readFilterInput(args)
	if err != nil {
		return err
	}
	if gitcrypt.IsEncryptedManifest(input) || gitcrypt.IsLFSPointer(input) {
		_, err := os.Stdout.Write(input)
		return err
	}
	runtime, err := NewFilterRuntime()
	if err != nil {
		return err
	}
	pathname := ""
	if len(args) == 1 {
		pathname = filepath.ToSlash(args[0])
	}
	var output []byte
	if isBinaryPath(pathname) {
		output, err = runtime.CleanLFS(pathname, input, true)
	} else {
		output, err = runtime.CleanWithPath(pathname, input)
	}
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(output)
	return err
}

// readFilterInput supports both stdin pipelines and git textconv path-argument invocation.
func readFilterInput(args []string) ([]byte, error) {
	if len(args) > 1 {
		return nil, fmt.Errorf("unexpected arguments: %s", strings.Join(args, " "))
	}
	if len(args) == 1 {
		raw, err := os.ReadFile(args[0])
		if err != nil {
			return nil, fmt.Errorf("failed to read %s: %w", args[0], err)
		}
		return raw, nil
	}
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return nil, fmt.Errorf("failed to read stdin: %w", err)
	}
	return raw, nil
}

// RunFilterProcess serves Git's long-running filter protocol for fast bulk clean/smudge operations.
func RunFilterProcess() error {
	reader := NewPktLineReader(os.Stdin)
	writer := NewPktLineWriter(os.Stdout)
	if err := performFilterHandshake(reader, writer); err != nil {
		return err
	}
	runtime, err := NewFilterRuntime()
	if err != nil {
		return err
	}
	defer func() {
		if runtime.lfsProcess != nil {
			_ = runtime.lfsProcess.Close()
		}
	}()

	for {
		header, err := reader.ReadStringMapUntilFlush()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("failed to read filter command header: %w", err)
		}
		if len(header) == 0 {
			continue
		}
		command := strings.TrimSpace(header["command"])
		pathname := strings.TrimSpace(header["pathname"])
		content, err := reader.ReadDataUntilFlush()
		if err != nil {
			return fmt.Errorf("failed to read filter command data: %w", err)
		}

		var output []byte
		switch command {
		case "smudge":
			if gitcrypt.IsLFSPointer(content) {
				output, err = runtime.SmudgeLFS(pathname, content, false)
			} else {
				output, err = runtime.Smudge(pathname, content)
			}
		case "clean":
			if gitcrypt.IsLFSPointer(content) {
				output = content
			} else if isBinaryPath(pathname) {
				output, err = runtime.CleanLFS(pathname, content, false)
			} else {
				output, err = runtime.CleanWithPath(pathname, content)
			}
		default:
			err = fmt.Errorf("unsupported filter command %q", command)
		}

		if err != nil {
			fmt.Fprintf(os.Stderr, "git-replycant: filter %s failed for %q: %v\n", command, pathname, err)
			if writeErr := writeFilterErrorResponse(writer, err); writeErr != nil {
				return writeErr
			}
			continue
		}
		if err := writeFilterSuccessResponse(writer, output); err != nil {
			return err
		}
	}
}

// NewFilterRuntime resolves repo and identity once so repeated operations avoid redundant setup work.
func NewFilterRuntime() (*FilterRuntime, error) {
	repoRoot, err := resolveRepoRoot()
	if err != nil {
		return nil, err
	}
	local, err := gitcrypt.LoadLocalIdentity(repoRoot)
	if err != nil {
		return nil, err
	}
	runtime := &FilterRuntime{
		repoRoot:            repoRoot,
		identity:            local.Identity,
		kekCache:            make(map[kekCacheKey][]byte),
		indexHashCache:      make(map[string][32]byte),
		indexEncryptedCache: make(map[string][]byte),
	}
	if err := requireFilterDatabaseVersion(runtime); err != nil {
		return nil, err
	}
	return runtime, nil
}

// requireFilterDatabaseVersion refuses to encrypt or decrypt in a
// repository whose marker is missing or not the compiled pin.
func requireFilterDatabaseVersion(r *FilterRuntime) error {
	raw, err := r.ReadRepoFile(gitcrypt.DatabaseVersionPath)
	if err != nil {
		return fmt.Errorf("%s is missing: %w", gitcrypt.DatabaseVersionPath, err)
	}
	return gitcrypt.RequireSupportedDatabaseVersion(raw)
}

// Smudge decrypts encrypted manifest envelopes and rejects plaintext so a
// hostile server cannot strip encryption and have clients accept attacker YAML.
func (r *FilterRuntime) Smudge(pathname string, input []byte) ([]byte, error) {
	if !gitcrypt.IsEncryptedManifest(input) {
		return nil, fmt.Errorf("plaintext manifest rejected: missing %s envelope", gitcrypt.ManifestHeader)
	}
	parsed, err := gitcrypt.ParseEncryptedManifestHeader(input)
	if err != nil {
		return nil, err
	}
	root, err := r.keySetRoot(pathname)
	if err != nil {
		return nil, err
	}
	kek, err := r.LoadKEK(root, parsed.KekEpoch)
	if err != nil {
		return nil, err
	}
	plaintext, decryptErr := gitcrypt.DecryptAesGcmCombined(kek, parsed.Ciphertext, nil)
	if decryptErr == nil {
		return plaintext, nil
	}
	decoded, decodeErr := base64.StdEncoding.DecodeString(strings.TrimSpace(string(parsed.Ciphertext)))
	if decodeErr != nil {
		return nil, decryptErr
	}
	return gitcrypt.DecryptAesGcmCombined(kek, decoded, nil)
}

// Clean encrypts plaintext manifests while passing already-encrypted content through unchanged.
func (r *FilterRuntime) Clean(input []byte) ([]byte, error) {
	return r.CleanWithPath("", input)
}

// SmudgeLFS resolves encrypted LFS pointers through git-lfs and decrypts downloaded bytes for checkout.
func (r *FilterRuntime) SmudgeLFS(pathname string, input []byte, oneShot bool) ([]byte, error) {
	cleanPointer, pointer, err := gitcrypt.StripReplycantHeaders(input)
	if err != nil {
		return nil, err
	}
	if pointer.KekEpoch < 1 || strings.TrimSpace(pointer.WrappedDEK) == "" {
		return nil, fmt.Errorf("missing replycant LFS metadata on %s", pathname)
	}
	var encrypted []byte
	env, envErr := r.lfsProxyEnvironment()
	if envErr != nil {
		return nil, envErr
	}
	if oneShot {
		encrypted, err = gitcrypt.RunLFSSmudgeOneShot(r.repoRoot, pathname, cleanPointer, env)
	} else {
		if err := r.ensureLFSProcess(); err != nil {
			return nil, err
		}
		encrypted, err = r.lfsProcess.Smudge(pathname, cleanPointer)
	}
	if err != nil {
		return nil, err
	}
	root, err := r.keySetRoot(pathname)
	if err != nil {
		return nil, err
	}
	kek, err := r.LoadKEK(root, pointer.KekEpoch)
	if err != nil {
		return nil, err
	}
	dek, err := gitcrypt.UnwrapDEK(pointer.WrappedDEK, kek, pointer.KekEpoch)
	if err != nil {
		return nil, err
	}
	return gitcrypt.DecryptChunked(encrypted, dek)
}

// CleanLFS encrypts binary payloads and stores a metadata-extended pointer compatible with git-lfs.
func (r *FilterRuntime) CleanLFS(pathname string, input []byte, oneShot bool) ([]byte, error) {
	if pathname != "" {
		indexPointer, matched, err := r.matchesIndexLFS(pathname, input, oneShot)
		if err != nil {
			return nil, err
		}
		if matched {
			return indexPointer, nil
		}
	}
	root, err := r.keySetRoot(pathname)
	if err != nil {
		return nil, err
	}
	epochRaw, err := r.ReadRepoFile(root + "/current")
	if err != nil {
		return nil, err
	}
	epoch, err := gitcrypt.ParseCurrentEpoch(epochRaw)
	if err != nil {
		return nil, err
	}
	kek, err := r.LoadKEK(root, epoch)
	if err != nil {
		return nil, err
	}
	dek, err := gitcrypt.NewDEK()
	if err != nil {
		return nil, err
	}
	encrypted, err := gitcrypt.EncryptChunked(input, dek)
	if err != nil {
		return nil, err
	}
	var pointer []byte
	env, envErr := r.lfsProxyEnvironment()
	if envErr != nil {
		return nil, envErr
	}
	if oneShot {
		pointer, err = gitcrypt.RunLFSCleanOneShot(r.repoRoot, pathname, encrypted, env)
	} else {
		if err := r.ensureLFSProcess(); err != nil {
			return nil, err
		}
		pointer, err = r.lfsProcess.Clean(pathname, encrypted)
	}
	if err != nil {
		return nil, err
	}
	wrappedDEK, err := gitcrypt.WrapDEK(kek, dek, epoch)
	if err != nil {
		return nil, err
	}
	return gitcrypt.AppendReplycantHeaders(pointer, epoch, wrappedDEK)
}

// CleanWithPath reuses staged encrypted bytes when plaintext is unchanged to keep git status clean.
func (r *FilterRuntime) CleanWithPath(pathname string, input []byte) ([]byte, error) {
	if gitcrypt.IsEncryptedManifest(input) {
		return input, nil
	}
	if pathname != "" {
		indexEncrypted, matched, err := r.matchesIndexManifest(pathname, input)
		if err != nil {
			return nil, err
		}
		if matched {
			return indexEncrypted, nil
		}
	}
	root, err := r.keySetRoot(pathname)
	if err != nil {
		return nil, err
	}
	epochRaw, err := r.ReadRepoFile(root + "/current")
	if err != nil {
		return nil, err
	}
	epoch, err := gitcrypt.ParseCurrentEpoch(epochRaw)
	if err != nil {
		return nil, err
	}
	kek, err := r.LoadKEK(root, epoch)
	if err != nil {
		return nil, err
	}
	return gitcrypt.EncryptManifestEnvelope(input, kek, epoch)
}

// matchesIndexManifest checks whether input matches the staged manifest by comparing SHA-256 hashes,
// avoiding retention of full plaintext in the long-lived filter process.
func (r *FilterRuntime) matchesIndexManifest(pathname string, input []byte) ([]byte, bool, error) {
	inputHash := sha256.Sum256(input)
	if cached, ok := r.indexHashCache[pathname]; ok {
		return r.indexEncryptedCache[pathname], cached == inputHash, nil
	}
	indexEncrypted, found, err := readIndexFileFromGit(r.repoRoot, pathname)
	if err != nil {
		return nil, false, err
	}
	if !found || !gitcrypt.IsEncryptedManifest(indexEncrypted) {
		return nil, false, nil
	}
	parsed, err := gitcrypt.ParseEncryptedManifestHeader(indexEncrypted)
	if err != nil {
		return nil, false, err
	}
	root, err := r.keySetRoot(pathname)
	if err != nil {
		return nil, false, err
	}
	kek, err := r.LoadKEK(root, parsed.KekEpoch)
	if err != nil {
		return nil, false, err
	}
	plaintext, decryptErr := gitcrypt.DecryptAesGcmCombined(kek, parsed.Ciphertext, nil)
	if decryptErr != nil {
		decoded, decodeErr := base64.StdEncoding.DecodeString(strings.TrimSpace(string(parsed.Ciphertext)))
		if decodeErr != nil {
			return nil, false, decryptErr
		}
		plaintext, decryptErr = gitcrypt.DecryptAesGcmCombined(kek, decoded, nil)
		if decryptErr != nil {
			return nil, false, decryptErr
		}
	}
	plaintextHash := sha256.Sum256(plaintext)
	r.indexHashCache[pathname] = plaintextHash
	r.indexEncryptedCache[pathname] = indexEncrypted
	return indexEncrypted, plaintextHash == inputHash, nil
}

// matchesIndexLFS checks whether input matches the staged LFS binary by comparing SHA-256 hashes,
// avoiding retention of full decrypted media in the long-lived filter process.
func (r *FilterRuntime) matchesIndexLFS(pathname string, input []byte, oneShot bool) ([]byte, bool, error) {
	inputHash := sha256.Sum256(input)
	if cached, ok := r.indexHashCache[pathname]; ok {
		return r.indexEncryptedCache[pathname], cached == inputHash, nil
	}
	indexPointer, found, err := readIndexFileFromGit(r.repoRoot, pathname)
	if err != nil {
		return nil, false, err
	}
	if !found || !gitcrypt.IsLFSPointer(indexPointer) {
		return nil, false, nil
	}
	parsed, err := gitcrypt.ParseLFSPointer(indexPointer)
	if err != nil {
		return nil, false, err
	}
	if parsed.KekEpoch < 1 || strings.TrimSpace(parsed.WrappedDEK) == "" {
		return nil, false, nil
	}
	plaintext, err := r.SmudgeLFS(pathname, indexPointer, oneShot)
	if err != nil {
		return nil, false, err
	}
	plaintextHash := sha256.Sum256(plaintext)
	r.indexHashCache[pathname] = plaintextHash
	r.indexEncryptedCache[pathname] = indexPointer
	return indexPointer, plaintextHash == inputHash, nil
}

// kekCacheKey separates epochs that share a number but belong to
// different key sets. Reusing one cache entry would decrypt a space
// with another space's KEK.
type kekCacheKey struct {
	root  string
	epoch int
}

// LoadKEK memoizes KEKs by key set and epoch. root is the directory
// that holds that key set's epochs, never a fallback.
func (r *FilterRuntime) LoadKEK(root string, epoch int) ([]byte, error) {
	key := kekCacheKey{root: root, epoch: epoch}
	if cached, ok := r.kekCache[key]; ok {
		return cached, nil
	}
	envelopePath := fmt.Sprintf("%s/epochs/%d.age", root, epoch)
	envelopeRaw, err := r.ReadRepoFile(envelopePath)
	if err != nil {
		return nil, fmt.Errorf("missing required KEK epoch file %s for LFS decryption epoch %d: %w", envelopePath, epoch, err)
	}
	kek, err := gitcrypt.UnwrapKEKFromAgeEnvelope(envelopeRaw, r.identity.AgePrivateKeyBase64)
	if err != nil {
		return nil, fmt.Errorf("failed to unwrap KEK for epoch %d: %w", epoch, err)
	}
	r.kekCache[key] = kek
	return kek, nil
}

// keySetRoot is the key set for this path. A space with encryption/current
// uses its own key set. A missing file means the space uses the global
// key set. Any other read error is returned so a glitch is not treated
// as permission to use the library KEK.
func (r *FilterRuntime) keySetRoot(pathname string) (string, error) {
	normalized := strings.TrimPrefix(strings.TrimSpace(filepath.ToSlash(pathname)), "./")
	space, ok := gitcrypt.SpaceFromPath(normalized)
	if !ok {
		return gitcrypt.GlobalKeySetRoot, nil
	}
	current := gitcrypt.SpaceKeySetRoot(space) + "/current"
	_, err := r.ReadRepoFile(current)
	own := err == nil
	if err != nil && !isMissingRepoFile(err) {
		return "", err
	}
	// A space that later gains or loses its own key set would let a
	// writer substitute a KEK the client has not accepted.
	if err := r.noteSpaceMode(space, own); err != nil {
		return "", err
	}
	if own {
		return gitcrypt.SpaceKeySetRoot(space), nil
	}
	return gitcrypt.GlobalKeySetRoot, nil
}

// noteSpaceMode records the first key set a space was seen with.
// Later reads must match it. The record lives beside the identity so
// a later pull still refuses a mode change.
func (r *FilterRuntime) noteSpaceMode(space string, own bool) error {
	if !r.spaceModesLoaded {
		modes, err := r.loadSpaceModes()
		if err != nil {
			return err
		}
		if r.spaceModes == nil {
			r.spaceModes = map[string]bool{}
		}
		for name, mode := range modes {
			r.spaceModes[name] = mode
		}
		r.spaceModesLoaded = true
	}
	if prev, ok := r.spaceModes[space]; ok && prev != own {
		return fmt.Errorf("encryption space %s changed key set", space)
	}
	if _, ok := r.spaceModes[space]; ok {
		return nil
	}
	r.spaceModes[space] = own
	return r.storeSpaceMode(space, own)
}

func (r *FilterRuntime) spaceModePath() (string, bool) {
	gitDir := filepath.Join(r.repoRoot, ".git")
	info, err := os.Stat(gitDir)
	if err != nil || !info.IsDir() {
		return "", false
	}
	return filepath.Join(gitDir, "replycant", "space-modes"), true
}

func (r *FilterRuntime) loadSpaceModes() (map[string]bool, error) {
	path, ok := r.spaceModePath()
	if !ok {
		return map[string]bool{}, nil
	}
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]bool{}, nil
	}
	if err != nil {
		return nil, err
	}
	modes := map[string]bool{}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		mode, name, found := strings.Cut(line, " ")
		if !found || (mode != "own" && mode != "global") || name == "" {
			return nil, fmt.Errorf("invalid space mode record %q", line)
		}
		modes[name] = mode == "own"
	}
	return modes, nil
}

func (r *FilterRuntime) storeSpaceMode(space string, own bool) error {
	path, ok := r.spaceModePath()
	if !ok {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	mode := "global"
	if own {
		mode = "own"
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintf(f, "%s %s\n", mode, space)
	return err
}

func isMissingRepoFile(err error) bool {
	if err == nil {
		return false
	}
	if os.IsNotExist(err) {
		return true
	}
	// git cat-file reports a missing path on stderr and only puts
	// "exit status 128" in Error().
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) && missingGitPathMessage(string(exitErr.Stderr)) {
		return true
	}
	return missingGitPathMessage(err.Error())
}

func missingGitPathMessage(msg string) bool {
	msg = strings.ToLower(msg)
	return strings.Contains(msg, "does not exist") ||
		strings.Contains(msg, "exists on disk, but not in") ||
		strings.Contains(msg, "not a valid object name")
}

// ReadRepoFile checks working tree, then index, then HEAD so filters can resolve files during initial checkout.
func (r *FilterRuntime) ReadRepoFile(relativePath string) ([]byte, error) {
	workingPath := filepath.Join(r.repoRoot, filepath.FromSlash(relativePath))
	raw, err := os.ReadFile(workingPath)
	if err == nil {
		return raw, nil
	}
	if !os.IsNotExist(err) {
		return nil, fmt.Errorf("failed to read %s: %w", relativePath, err)
	}
	indexRaw, found, indexErr := readIndexFileFromGit(r.repoRoot, relativePath)
	if indexErr == nil && found {
		return indexRaw, nil
	}
	if indexErr != nil {
		return nil, indexErr
	}
	headRaw, headErr := readHeadFileFromGit(r.repoRoot, relativePath)
	if headErr == nil {
		return headRaw, nil
	}
	remoteRaw, remoteErr := readOriginFileFromGit(r.repoRoot, relativePath)
	if remoteErr == nil {
		return remoteRaw, nil
	}
	// The first checkout smudges before HEAD exists. A missing path is
	// then reported by the remote tip, not by the invalid HEAD name.
	if isMissingRepoFile(remoteErr) {
		return nil, remoteErr
	}
	if isMissingRepoFile(headErr) {
		return nil, headErr
	}
	return nil, headErr
}

// performFilterHandshake negotiates protocol version and capabilities with git.
func performFilterHandshake(reader *PktLineReader, writer *PktLineWriter) error {
	clientHello, err := reader.ReadUntilFlush()
	if err != nil {
		return fmt.Errorf("failed to read filter client hello: %w", err)
	}
	if !containsPacketLine(clientHello, "git-filter-client") {
		return fmt.Errorf("invalid filter handshake: missing git-filter-client")
	}
	if !containsPacketLine(clientHello, "version=2") {
		return fmt.Errorf("unsupported filter protocol version")
	}

	if err := writer.WriteString("git-filter-server\n"); err != nil {
		return err
	}
	if err := writer.WriteString("version=2\n"); err != nil {
		return err
	}
	if err := writer.WriteFlush(); err != nil {
		return err
	}
	if err := writer.Flush(); err != nil {
		return err
	}

	requestedCaps, err := reader.ReadUntilFlush()
	if err != nil {
		return fmt.Errorf("failed to read filter capabilities: %w", err)
	}
	allowed := map[string]bool{
		"capability=clean":  true,
		"capability=smudge": true,
	}
	for _, packet := range requestedCaps {
		line := strings.TrimSpace(string(packet))
		if allowed[line] {
			if err := writer.WriteString(line + "\n"); err != nil {
				return err
			}
		}
	}
	if err := writer.WriteFlush(); err != nil {
		return err
	}
	return writer.Flush()
}

// writeFilterSuccessResponse emits a successful response frame set for a filter request.
func writeFilterSuccessResponse(writer *PktLineWriter, output []byte) error {
	if err := writer.WriteString("status=success\n"); err != nil {
		return err
	}
	if err := writer.WriteFlush(); err != nil {
		return err
	}
	if err := writer.WriteDataFrames(output); err != nil {
		return err
	}
	if err := writer.WriteFlush(); err != nil {
		return err
	}
	if err := writer.WriteString("status=success\n"); err != nil {
		return err
	}
	if err := writer.WriteFlush(); err != nil {
		return err
	}
	return writer.Flush()
}

// writeFilterErrorResponse propagates processing failures back to git with protocol-compliant frames.
func writeFilterErrorResponse(writer *PktLineWriter, processErr error) error {
	if err := writer.WriteString("status=error\n"); err != nil {
		return err
	}
	if err := writer.WriteString("error=" + sanitizeFilterError(processErr.Error()) + "\n"); err != nil {
		return err
	}
	if err := writer.WriteFlush(); err != nil {
		return err
	}
	if err := writer.WriteFlush(); err != nil {
		return err
	}
	if err := writer.WriteString("status=error\n"); err != nil {
		return err
	}
	if err := writer.WriteFlush(); err != nil {
		return err
	}
	return writer.Flush()
}

// resolveRepoRoot ensures filter operations read encryption metadata from the active repository.
func resolveRepoRoot() (string, error) {
	cmd := exec.Command("git", "rev-parse", "--show-toplevel")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to resolve git repository root: %w", err)
	}
	root := strings.TrimSpace(string(out))
	if root == "" {
		return "", fmt.Errorf("failed to resolve git repository root")
	}
	return root, nil
}

// readHeadFileFromGit pulls a file from HEAD when checkout ordering has not written it to disk yet.
func readHeadFileFromGit(repoRoot string, relativePath string) ([]byte, error) {
	objectPath := "HEAD:" + filepath.ToSlash(relativePath)
	cmd := exec.Command("git", "-C", repoRoot, "cat-file", "-p", objectPath)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to read %s from HEAD: %w", relativePath, err)
	}
	return out, nil
}

// readOriginFileFromGit covers the first checkout, when local HEAD is still
// unborn and earlier-sorted paths smudge before gitdb/ is in the index.
func readOriginFileFromGit(repoRoot string, relativePath string) ([]byte, error) {
	branch, err := ResolveDefaultRemoteBranch(repoRoot)
	if err != nil {
		return nil, err
	}
	objectPath := "origin/" + branch + ":" + filepath.ToSlash(relativePath)
	cmd := exec.Command("git", "-C", repoRoot, "cat-file", "-p", objectPath)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to read %s from origin/%s: %w", relativePath, branch, err)
	}
	return out, nil
}

// readIndexFileFromGit reads a staged path from the index for idempotent clean filtering.
func readIndexFileFromGit(repoRoot string, relativePath string) ([]byte, bool, error) {
	objectPath := ":" + filepath.ToSlash(relativePath)
	cmd := exec.Command("git", "-C", repoRoot, "show", objectPath)
	out, err := cmd.Output()
	if err == nil {
		return out, true, nil
	}
	exitErr, ok := err.(*exec.ExitError)
	if !ok {
		return nil, false, fmt.Errorf("failed to read %s from index: %w", relativePath, err)
	}
	stderr := strings.ToLower(string(exitErr.Stderr))
	if strings.Contains(stderr, "exists on disk, but not in the index") ||
		strings.Contains(stderr, "path does not exist") ||
		strings.Contains(stderr, "neither on disk nor in the index") ||
		strings.Contains(stderr, "not in the index") ||
		strings.Contains(stderr, "pathspec") {
		return nil, false, nil
	}
	return nil, false, fmt.Errorf("failed to read %s from index: %s", relativePath, strings.TrimSpace(string(exitErr.Stderr)))
}

// containsPacketLine checks whether a pkt-line group contains a specific trimmed text line.
func containsPacketLine(lines [][]byte, target string) bool {
	for _, line := range lines {
		if strings.TrimSpace(string(line)) == target {
			return true
		}
	}
	return false
}

// sanitizeFilterError keeps protocol metadata one-line so git can parse error packets safely.
func sanitizeFilterError(value string) string {
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	if len(value) > 500 {
		return value[:500] + "..."
	}
	return value
}

// parseEpochFromPath supports optional future path-based optimizations and test helpers.
func parseEpochFromPath(path string) (int, bool) {
	normalized := strings.TrimPrefix(filepath.ToSlash(path), "./")
	const marker = "/epochs/"
	idx := strings.LastIndex(normalized, marker)
	if idx < 0 || !strings.HasSuffix(normalized, ".age") {
		return 0, false
	}
	dir := normalized[:idx]
	if dir != gitcrypt.GlobalKeySetRoot && !strings.HasSuffix(dir, "/encryption") {
		return 0, false
	}
	name := strings.TrimSuffix(normalized[idx+len(marker):], ".age")
	epoch, err := strconv.Atoi(name)
	if err != nil || epoch < 1 {
		return 0, false
	}
	return epoch, true
}

// ensureLFSProcess lazily starts git-lfs filter-process so repeated file operations reuse one process.
func (r *FilterRuntime) ensureLFSProcess() error {
	if r.lfsProcess != nil {
		return nil
	}
	env, err := r.lfsProxyEnvironment()
	if err != nil {
		return err
	}
	process, err := gitcrypt.StartLFSFilterProcess(r.repoRoot, env)
	if err != nil {
		return err
	}
	r.lfsProcess = process
	return nil
}

// lfsProxyEnvironment starts the repository tailnet agent once per filter
// process. git-lfs is a child process and cannot see the agent otherwise.
func (r *FilterRuntime) lfsProxyEnvironment() ([]string, error) {
	if r.lfsEnvReady {
		return r.lfsExtraEnv, nil
	}
	proxyURL, err := ensureRepoProxy(r.repoRoot)
	if err != nil {
		return nil, err
	}
	r.lfsExtraEnv = lfsProxyEnv(proxyURL)
	r.lfsEnvReady = true
	return r.lfsExtraEnv, nil
}

// isBinaryPath scopes LFS clean behavior to binary payload paths only.
func isBinaryPath(pathname string) bool {
	normalized := strings.TrimPrefix(strings.TrimSpace(filepath.ToSlash(pathname)), "./")
	return gitcrypt.IsBinaryPath(normalized)
}
