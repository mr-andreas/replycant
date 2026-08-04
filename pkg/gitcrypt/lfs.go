package gitcrypt

import (
	"bufio"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
)

const (
	// LFSPointerHeader marks canonical Git LFS pointer files before replycant metadata extensions.
	LFSPointerHeader = "version https://git-lfs.github.com/spec/v1\n"
	// ChunkOverheadBytes is the per-chunk AES-GCM tag left on the wire after dropping the nonce.
	ChunkOverheadBytes = 16
	// ChunkSize is the repo-wide plaintext chunk size. 64 KiB minimizes seek waste on
	// decryptd range opens while staying within ~10% of 1 MiB browser decrypt throughput.
	ChunkSize = 65_536
	// chunkAADPrefix binds LFS chunk seals to the v2 position-authenticated framing contract.
	chunkAADPrefix = "replycant-lfs-chunk-v1"
	// dekWrapAADPrefix binds wrapped DEKs to a kek-epoch so pointer metadata cannot be swapped across epochs.
	dekWrapAADPrefix = "replycant-dek-wrap-v1"
)

// LFSPointer carries parsed standard and replycant extension fields from one pointer file.
type LFSPointer struct {
	Version    string
	OID        string
	Size       int64
	KekEpoch   int
	WrappedDEK string
}

// LFSFilterProcess wraps one long-lived git-lfs filter-process to reuse HTTP keep-alive connections.
type LFSFilterProcess struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	reader *pktLineReader
	writer *pktLineWriter
	mu     sync.Mutex
}

// IsLFSPointer identifies standard Git LFS pointer content before any download/decrypt steps run.
func IsLFSPointer(raw []byte) bool {
	return bytes.HasPrefix(raw, []byte(LFSPointerHeader))
}

// ParseLFSPointer extracts standard LFS fields plus optional replycant encryption metadata.
func ParseLFSPointer(raw []byte) (LFSPointer, error) {
	if !IsLFSPointer(raw) {
		return LFSPointer{}, fmt.Errorf("not a git-lfs pointer")
	}
	lines := strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n")
	out := LFSPointer{}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		switch {
		case strings.HasPrefix(trimmed, "version "):
			out.Version = strings.TrimSpace(strings.TrimPrefix(trimmed, "version "))
		case strings.HasPrefix(trimmed, "oid sha256:"):
			out.OID = strings.TrimSpace(strings.TrimPrefix(trimmed, "oid sha256:"))
		case strings.HasPrefix(trimmed, "size "):
			parsed, err := strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(trimmed, "size ")), 10, 64)
			if err != nil {
				return LFSPointer{}, fmt.Errorf("invalid lfs pointer size: %w", err)
			}
			out.Size = parsed
		case strings.HasPrefix(trimmed, "x-replycant-kek-epoch "):
			parsed, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(trimmed, "x-replycant-kek-epoch ")))
			if err != nil {
				return LFSPointer{}, fmt.Errorf("invalid x-replycant-kek-epoch: %w", err)
			}
			out.KekEpoch = parsed
		case strings.HasPrefix(trimmed, "x-replycant-wrapped-dek "):
			out.WrappedDEK = strings.TrimSpace(strings.TrimPrefix(trimmed, "x-replycant-wrapped-dek "))
		}
	}
	if out.Version != "https://git-lfs.github.com/spec/v1" {
		return LFSPointer{}, fmt.Errorf("invalid lfs pointer version")
	}
	if out.OID == "" {
		return LFSPointer{}, fmt.Errorf("missing lfs pointer oid")
	}
	if out.Size < 0 {
		return LFSPointer{}, fmt.Errorf("invalid lfs pointer size")
	}
	return out, nil
}

// StripReplycantHeaders removes replycant extension headers so git-lfs can parse the pointer.
func StripReplycantHeaders(raw []byte) ([]byte, LFSPointer, error) {
	parsed, err := ParseLFSPointer(raw)
	if err != nil {
		return nil, LFSPointer{}, err
	}
	lines := strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n")
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "x-replycant-") {
			continue
		}
		if trimmed == "" {
			continue
		}
		filtered = append(filtered, line)
	}
	return []byte(strings.Join(filtered, "\n") + "\n"), parsed, nil
}

// AppendReplycantHeaders adds repository encryption metadata onto a standard LFS pointer.
// Chunk size is intentionally omitted: it is a compile-time constant, not attacker-supplied geometry.
func AppendReplycantHeaders(raw []byte, epoch int, wrappedDEK string) ([]byte, error) {
	if epoch < 1 {
		return nil, fmt.Errorf("invalid kek epoch %d", epoch)
	}
	if strings.TrimSpace(wrappedDEK) == "" {
		return nil, fmt.Errorf("wrapped DEK is required")
	}
	cleanPointer, _, err := StripReplycantHeaders(raw)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(cleanPointer)), "\n")
	out := make([]string, 0, len(lines)+2)
	inserted := false
	for _, line := range lines {
		out = append(out, line)
		if strings.HasPrefix(strings.TrimSpace(line), "size ") && !inserted {
			out = append(out,
				fmt.Sprintf("x-replycant-kek-epoch %d", epoch),
				fmt.Sprintf("x-replycant-wrapped-dek %s", wrappedDEK),
			)
			inserted = true
		}
	}
	if !inserted {
		return nil, fmt.Errorf("missing size line in lfs pointer")
	}
	return []byte(strings.Join(out, "\n") + "\n"), nil
}

// ChunkNonce derives the 12-byte AES-GCM nonce for chunk index so encryptors never
// place an attacker-controlled nonce on the wire.
func ChunkNonce(index uint64) []byte {
	nonce := make([]byte, 12)
	binary.BigEndian.PutUint64(nonce[4:], index)
	return nonce
}

// ChunkAAD binds each seal to its index and last-chunk status so reorder and
// trailing truncation fail authentication.
func ChunkAAD(index uint64, isLast bool) []byte {
	aad := make([]byte, 0, len(chunkAADPrefix)+8+1)
	aad = append(aad, chunkAADPrefix...)
	var indexBytes [8]byte
	binary.BigEndian.PutUint64(indexBytes[:], index)
	aad = append(aad, indexBytes[:]...)
	if isLast {
		aad = append(aad, 1)
	} else {
		aad = append(aad, 0)
	}
	return aad
}

// DEKWrapAAD binds a wrapped DEK to its kek-epoch so pointer metadata cannot be
// moved across epochs without detection.
func DEKWrapAAD(kekEpoch uint64) []byte {
	aad := make([]byte, 0, len(dekWrapAADPrefix)+8)
	aad = append(aad, dekWrapAADPrefix...)
	var epochBytes [8]byte
	binary.BigEndian.PutUint64(epochBytes[:], kekEpoch)
	aad = append(aad, epochBytes[:]...)
	return aad
}

// WrapDEK seals one per-object DEK with the repository KEK so pointers can carry decrypt metadata.
func WrapDEK(kek []byte, dek []byte, kekEpoch int) (string, error) {
	if kekEpoch < 1 {
		return "", fmt.Errorf("invalid kek epoch %d", kekEpoch)
	}
	combined, err := EncryptAesGcmCombined(kek, dek, DEKWrapAAD(uint64(kekEpoch)))
	if err != nil {
		return "", fmt.Errorf("failed to wrap DEK: %w", err)
	}
	return base64.StdEncoding.EncodeToString(combined), nil
}

// UnwrapDEK decrypts pointer metadata into the per-object DEK required for chunk decryption.
func UnwrapDEK(wrappedDEK string, kek []byte, kekEpoch int) ([]byte, error) {
	if kekEpoch < 1 {
		return nil, fmt.Errorf("invalid kek epoch %d", kekEpoch)
	}
	combined, err := base64.StdEncoding.DecodeString(strings.TrimSpace(wrappedDEK))
	if err != nil {
		return nil, fmt.Errorf("invalid wrapped DEK base64: %w", err)
	}
	dek, err := DecryptAesGcmCombined(kek, combined, DEKWrapAAD(uint64(kekEpoch)))
	if err != nil {
		return nil, fmt.Errorf("failed to unwrap DEK: %w", err)
	}
	if len(dek) != 32 {
		return nil, fmt.Errorf("invalid unwrapped DEK length %d", len(dek))
	}
	return dek, nil
}

// NewDEK creates one random 32-byte key so each object gets independent encryption material.
func NewDEK() ([]byte, error) {
	dek := make([]byte, 32)
	if _, err := rand.Read(dek); err != nil {
		return nil, fmt.Errorf("failed to generate DEK: %w", err)
	}
	return dek, nil
}

// EncryptChunked writes ciphertext||tag frames with index-derived nonces and AAD
// so each chunk is bound to its position without storing the nonce on the wire.
func EncryptChunked(plaintext []byte, dek []byte) ([]byte, error) {
	if len(plaintext) == 0 {
		return []byte{}, nil
	}
	block, err := aes.NewCipher(dek)
	if err != nil {
		return nil, fmt.Errorf("failed to create cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCM: %w", err)
	}
	n := (len(plaintext) + ChunkSize - 1) / ChunkSize
	out := make([]byte, 0, len(plaintext)+n*ChunkOverheadBytes)
	for i := 0; i < n; i++ {
		start := i * ChunkSize
		end := start + ChunkSize
		if end > len(plaintext) {
			end = len(plaintext)
		}
		sealed := gcm.Seal(nil, ChunkNonce(uint64(i)), plaintext[start:end], ChunkAAD(uint64(i), i == n-1))
		out = append(out, sealed...)
	}
	return out, nil
}

// DecryptChunked opens concatenated ciphertext||tag frames using index-derived
// nonces and AAD so reorder and trailing truncation fail authentication.
func DecryptChunked(encrypted []byte, dek []byte) ([]byte, error) {
	if len(encrypted) == 0 {
		return []byte{}, nil
	}
	block, err := aes.NewCipher(dek)
	if err != nil {
		return nil, fmt.Errorf("failed to create cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCM: %w", err)
	}
	maxEncryptedChunk := ChunkSize + ChunkOverheadBytes
	out := make([]byte, 0, len(encrypted))
	for start, index := 0, uint64(0); start < len(encrypted); index++ {
		remaining := len(encrypted) - start
		chunkLen := maxEncryptedChunk
		if remaining < maxEncryptedChunk {
			chunkLen = remaining
		}
		if chunkLen < ChunkOverheadBytes {
			return nil, fmt.Errorf("encrypted chunk too short")
		}
		isLast := start+chunkLen == len(encrypted)
		plaintextChunk, err := gcm.Open(nil, ChunkNonce(index), encrypted[start:start+chunkLen], ChunkAAD(index, isLast))
		if err != nil {
			return nil, fmt.Errorf("failed to decrypt chunk: %w", err)
		}
		out = append(out, plaintextChunk...)
		start += chunkLen
	}
	return out, nil
}

// StartLFSFilterProcess starts git-lfs filter-process and negotiates pkt-line capabilities once.
func StartLFSFilterProcess(repoRoot string) (*LFSFilterProcess, error) {
	cmd := buildLFSFilterProcessCommand(repoRoot)
	cmd.Dir = repoRoot
	cmd.Env = gitNonInteractiveEnv()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open git-lfs stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open git-lfs stdout: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open git-lfs stderr: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start git-lfs filter-process: %w", err)
	}
	p := &LFSFilterProcess{
		cmd:    cmd,
		stdin:  stdin,
		reader: newPktLineReader(stdout),
		writer: newPktLineWriter(stdin),
	}
	if err := p.handshake(); err != nil {
		stderrBytes, _ := io.ReadAll(stderr)
		_ = stdin.Close()
		_ = cmd.Wait()
		if len(stderrBytes) > 0 {
			return nil, fmt.Errorf("git-lfs handshake failed: %w: %s", err, strings.TrimSpace(string(stderrBytes)))
		}
		return nil, fmt.Errorf("git-lfs handshake failed: %w", err)
	}
	go func() {
		_, _ = io.Copy(os.Stderr, stderr)
	}()
	return p, nil
}

// Close shuts down the child git-lfs process cleanly when filter runtime exits.
func (p *LFSFilterProcess) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stdin != nil {
		_ = p.stdin.Close()
		p.stdin = nil
	}
	if p.cmd == nil {
		return nil
	}
	err := p.cmd.Wait()
	p.cmd = nil
	return err
}

// Smudge sends one pointer payload to git-lfs smudge mode over the persistent pkt-line session.
func (p *LFSFilterProcess) Smudge(pathname string, content []byte) ([]byte, error) {
	return p.request("smudge", pathname, content)
}

// Clean sends one encrypted binary payload to git-lfs clean mode over the persistent pkt-line session.
func (p *LFSFilterProcess) Clean(pathname string, content []byte) ([]byte, error) {
	return p.request("clean", pathname, content)
}

// RunLFSSmudgeOneShot supports single-file workflows where starting a persistent process is unnecessary.
func RunLFSSmudgeOneShot(repoRoot string, pathname string, content []byte) ([]byte, error) {
	return runLFSOneShot(repoRoot, "smudge", pathname, content)
}

// RunLFSCleanOneShot supports single-file workflows where starting a persistent process is unnecessary.
func RunLFSCleanOneShot(repoRoot string, pathname string, content []byte) ([]byte, error) {
	return runLFSOneShot(repoRoot, "clean", pathname, content)
}

// buildLFSFilterProcessCommand prefers git-lfs binary and falls back to git lfs subcommand for compatibility.
func buildLFSFilterProcessCommand(repoRoot string) *exec.Cmd {
	if _, err := exec.LookPath("git-lfs"); err == nil {
		return exec.Command("git-lfs", "filter-process")
	}
	return exec.Command("git", "lfs", "filter-process")
}

// handshake mirrors git's client-side pkt-line negotiation so git-lfs enables filter capabilities.
func (p *LFSFilterProcess) handshake() error {
	if err := p.writer.writeString("git-filter-client\n"); err != nil {
		return err
	}
	if err := p.writer.writeString("version=2\n"); err != nil {
		return err
	}
	if err := p.writer.writeFlush(); err != nil {
		return err
	}
	if err := p.writer.flush(); err != nil {
		return err
	}
	serverHello, err := p.reader.readUntilFlush()
	if err != nil {
		return err
	}
	if !containsPacketLine(serverHello, "git-filter-server") {
		return fmt.Errorf("missing git-filter-server handshake")
	}
	if !containsPacketLine(serverHello, "version=2") {
		return fmt.Errorf("unsupported git-lfs filter protocol version")
	}
	if err := p.writer.writeString("capability=clean\n"); err != nil {
		return err
	}
	if err := p.writer.writeString("capability=smudge\n"); err != nil {
		return err
	}
	if err := p.writer.writeFlush(); err != nil {
		return err
	}
	if err := p.writer.flush(); err != nil {
		return err
	}
	ackCaps, err := p.reader.readUntilFlush()
	if err != nil {
		return err
	}
	if !containsPacketLine(ackCaps, "capability=clean") {
		return fmt.Errorf("git-lfs did not acknowledge clean capability")
	}
	if !containsPacketLine(ackCaps, "capability=smudge") {
		return fmt.Errorf("git-lfs did not acknowledge smudge capability")
	}
	return nil
}

// request performs one clean/smudge exchange over the persistent git-lfs pkt-line stream.
func (p *LFSFilterProcess) request(command string, pathname string, content []byte) ([]byte, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cmd == nil {
		return nil, fmt.Errorf("git-lfs filter-process is not running")
	}
	if err := p.writer.writeString("command=" + command + "\n"); err != nil {
		return nil, err
	}
	if strings.TrimSpace(pathname) != "" {
		if err := p.writer.writeString("pathname=" + pathname + "\n"); err != nil {
			return nil, err
		}
	}
	if err := p.writer.writeFlush(); err != nil {
		return nil, err
	}
	if err := p.writer.writeDataFrames(content); err != nil {
		return nil, err
	}
	if err := p.writer.writeFlush(); err != nil {
		return nil, err
	}
	if err := p.writer.flush(); err != nil {
		return nil, err
	}

	responseHeader, err := p.reader.readStringMapUntilFlush()
	if err != nil {
		return nil, err
	}
	status := strings.TrimSpace(responseHeader["status"])
	data, err := p.reader.readDataUntilFlush()
	if err != nil {
		return nil, err
	}
	footer, err := p.reader.readStringMapUntilFlush()
	if err != nil {
		return nil, err
	}
	footerStatus := strings.TrimSpace(footer["status"])
	if status == "error" || footerStatus == "error" {
		message := strings.TrimSpace(responseHeader["error"])
		if message == "" {
			message = strings.TrimSpace(footer["error"])
		}
		if message == "" {
			message = "git-lfs returned filter-process error"
		}
		return nil, errors.New(message)
	}
	if status != "success" || footerStatus != "success" {
		return nil, fmt.Errorf("unexpected git-lfs response status header=%q footer=%q", status, footerStatus)
	}
	return data, nil
}

// runLFSOneShot delegates one payload to git-lfs clean/smudge for one-off command usage.
func runLFSOneShot(repoRoot string, mode string, pathname string, content []byte) ([]byte, error) {
	args := []string{"lfs", mode}
	if strings.TrimSpace(pathname) != "" {
		args = append(args, "--", pathname)
	}
	cmd := exec.Command("git", args...)
	cmd.Env = gitNonInteractiveEnv()
	if strings.TrimSpace(repoRoot) != "" {
		cmd.Dir = repoRoot
	}
	cmd.Stdin = bytes.NewReader(content)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("git lfs %s failed: %w: %s", mode, err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
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

// gitNonInteractiveEnv prevents credential prompts so onboarding only relies on mTLS authorization.
func gitNonInteractiveEnv() []string {
	env := append([]string{}, os.Environ()...)
	env = append(env,
		"GIT_TERMINAL_PROMPT=0",
		"GIT_ASKPASS=",
		"SSH_ASKPASS=",
		"GCM_INTERACTIVE=never",
	)
	return env
}

// pktLineReader parses Git packet-line frames from one stream.
type pktLineReader struct {
	reader *bufio.Reader
}

// pktLineWriter encodes packet-line frames to one stream.
type pktLineWriter struct {
	writer *bufio.Writer
}

// newPktLineReader wraps one stream with packet-line parsing helpers.
func newPktLineReader(r io.Reader) *pktLineReader {
	return &pktLineReader{reader: bufio.NewReader(r)}
}

// newPktLineWriter wraps one stream with packet-line encoding helpers.
func newPktLineWriter(w io.Writer) *pktLineWriter {
	return &pktLineWriter{writer: bufio.NewWriter(w)}
}

// readPacket reads one packet-line payload or returns nil for flush packets.
func (r *pktLineReader) readPacket() ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r.reader, header); err != nil {
		return nil, err
	}
	length, err := strconv.ParseInt(string(header), 16, 32)
	if err != nil {
		return nil, fmt.Errorf("invalid pkt-line header %q: %w", string(header), err)
	}
	if length == 0 {
		return nil, nil
	}
	if length < 4 {
		return nil, fmt.Errorf("invalid pkt-line length %d", length)
	}
	payloadLength := int(length) - 4
	payload := make([]byte, payloadLength)
	if _, err := io.ReadFull(r.reader, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

// readUntilFlush collects packets until a flush packet is encountered.
func (r *pktLineReader) readUntilFlush() ([][]byte, error) {
	out := make([][]byte, 0, 8)
	for {
		packet, err := r.readPacket()
		if err != nil {
			return nil, err
		}
		if packet == nil {
			return out, nil
		}
		out = append(out, packet)
	}
}

// readStringMapUntilFlush parses key=value packet lines into a map.
func (r *pktLineReader) readStringMapUntilFlush() (map[string]string, error) {
	packets, err := r.readUntilFlush()
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, packet := range packets {
		line := strings.TrimSpace(string(packet))
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			out[parts[0]] = parts[1]
			continue
		}
		out[line] = ""
	}
	return out, nil
}

// readDataUntilFlush concatenates binary packet frames into one payload.
func (r *pktLineReader) readDataUntilFlush() ([]byte, error) {
	packets, err := r.readUntilFlush()
	if err != nil {
		return nil, err
	}
	total := 0
	for _, packet := range packets {
		total += len(packet)
	}
	out := make([]byte, 0, total)
	for _, packet := range packets {
		out = append(out, packet...)
	}
	return out, nil
}

// writePacket writes one packet-line frame.
func (w *pktLineWriter) writePacket(payload []byte) error {
	if len(payload) > 0xFFFF-4 {
		return fmt.Errorf("pkt-line payload too large: %d", len(payload))
	}
	if _, err := fmt.Fprintf(w.writer, "%04x", len(payload)+4); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.writer.Write(payload)
	return err
}

// writeString writes one textual packet line.
func (w *pktLineWriter) writeString(value string) error {
	return w.writePacket([]byte(value))
}

// writeFlush writes one flush packet.
func (w *pktLineWriter) writeFlush() error {
	_, err := w.writer.WriteString("0000")
	return err
}

// writeDataFrames splits binary payloads into packet-line sized chunks.
func (w *pktLineWriter) writeDataFrames(data []byte) error {
	const maxPayload = 65516
	for start := 0; start < len(data); start += maxPayload {
		end := start + maxPayload
		if end > len(data) {
			end = len(data)
		}
		if err := w.writePacket(data[start:end]); err != nil {
			return err
		}
	}
	return nil
}

// flush flushes buffered pkt-line output.
func (w *pktLineWriter) flush() error {
	return w.writer.Flush()
}
