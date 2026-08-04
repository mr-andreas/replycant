package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParseLFSPointer verifies pointer parsing handles both standard and replycant metadata fields.
func TestParseLFSPointer(t *testing.T) {
	raw := []byte("version https://git-lfs.github.com/spec/v1\noid sha256:abc123\nsize 10\nx-replycant-kek-epoch 2\nx-replycant-wrapped-dek wrapped\n")
	parsed, err := gitcrypt.ParseLFSPointer(raw)
	require.NoError(t, err)
	assert.Equal(t, "https://git-lfs.github.com/spec/v1", parsed.Version)
	assert.Equal(t, "abc123", parsed.OID)
	assert.EqualValues(t, 10, parsed.Size)
	assert.Equal(t, 2, parsed.KekEpoch)
	assert.Equal(t, "wrapped", parsed.WrappedDEK)
}

// TestStripAndAppendReplycantHeaders verifies metadata can be removed for git-lfs and restored afterwards.
func TestStripAndAppendReplycantHeaders(t *testing.T) {
	raw := []byte("version https://git-lfs.github.com/spec/v1\noid sha256:abc123\nsize 10\nx-replycant-kek-epoch 2\nx-replycant-wrapped-dek wrapped\n")
	stripped, parsed, err := gitcrypt.StripReplycantHeaders(raw)
	require.NoError(t, err)
	assert.Equal(t, 2, parsed.KekEpoch)
	assert.Equal(t, "wrapped", parsed.WrappedDEK)
	assert.NotContains(t, string(stripped), "x-replycant-")

	restored, err := gitcrypt.AppendReplycantHeaders(stripped, parsed.KekEpoch, parsed.WrappedDEK)
	require.NoError(t, err)
	assert.Contains(t, string(restored), "x-replycant-kek-epoch 2")
	assert.Contains(t, string(restored), "x-replycant-wrapped-dek wrapped")
	assert.NotContains(t, string(restored), "x-replycant-chunk-size")
}

// TestWrapAndUnwrapDEK verifies wrapped metadata roundtrips with AES-GCM integrity checks.
func TestWrapAndUnwrapDEK(t *testing.T) {
	kek := bytes.Repeat([]byte{0x01}, 32)
	dek := bytes.Repeat([]byte{0x02}, 32)
	wrapped, err := gitcrypt.WrapDEK(kek, dek, 1)
	require.NoError(t, err)
	unwrapped, err := gitcrypt.UnwrapDEK(wrapped, kek, 1)
	require.NoError(t, err)
	assert.Equal(t, dek, unwrapped)
}

// TestChunkedEncryptDecryptRoundtrip verifies chunk framing preserves bytes through encrypt/decrypt.
func TestChunkedEncryptDecryptRoundtrip(t *testing.T) {
	dek := bytes.Repeat([]byte{0x03}, 32)
	plaintext := bytes.Repeat([]byte("payload-"), 5000)
	encrypted, err := gitcrypt.EncryptChunked(plaintext, dek)
	require.NoError(t, err)
	require.NotEmpty(t, encrypted)
	roundtrip, err := gitcrypt.DecryptChunked(encrypted, dek)
	require.NoError(t, err)
	assert.Equal(t, plaintext, roundtrip)
}

// TestLFSFilterProcessPktline verifies the long-lived lfs process wrapper performs handshake and request framing.
func TestLFSFilterProcessPktline(t *testing.T) {
	repoDir := testInitRepo(t)
	fakeBin := buildFakeGitLFSTestBinary(t)
	t.Setenv("PATH", filepath.Dir(fakeBin)+string(os.PathListSeparator)+os.Getenv("PATH"))

	process, err := gitcrypt.StartLFSFilterProcess(repoDir)
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = process.Close()
	})

	smudgeOut, err := process.Smudge("binary/test.bin", []byte("abc"))
	require.NoError(t, err)
	assert.Equal(t, []byte("SMUDGE:abc"), smudgeOut)

	cleanOut, err := process.Clean("binary/test.bin", []byte("xyz"))
	require.NoError(t, err)
	assert.Equal(t, []byte("CLEAN:xyz"), cleanOut)
}

// TestLFSFilterProcessStderrDeadlock verifies stderr flooding no longer blocks smudge responses.
func TestLFSFilterProcessStderrDeadlock(t *testing.T) {
	repoDir := testInitRepo(t)
	fakeBin := buildFakeGitLFSStderrFloodBinary(t)
	t.Setenv("PATH", filepath.Dir(fakeBin)+string(os.PathListSeparator)+os.Getenv("PATH"))

	process, err := gitcrypt.StartLFSFilterProcess(repoDir)
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = process.Close()
	})

	done := make(chan struct{})
	var smudgeOut []byte
	var smudgeErr error
	go func() {
		smudgeOut, smudgeErr = process.Smudge("binary/test.bin", []byte("abc"))
		close(done)
	}()

	select {
	case <-done:
		require.NoError(t, smudgeErr)
		assert.Equal(t, []byte("SMUDGE:abc"), smudgeOut)
	case <-time.After(10 * time.Second):
		t.Fatal("LFS smudge deadlocked while git-lfs was writing stderr")
	}
}

// buildFakeGitLFSTestBinary creates a deterministic git-lfs shim for protocol-level unit tests.
func buildFakeGitLFSTestBinary(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	source := filepath.Join(dir, "fake_git_lfs.go")
	bin := filepath.Join(dir, "git-lfs")
	code := `package main
import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)
func readPacket(r *bufio.Reader) ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, err
	}
	n, err := strconv.ParseInt(string(header), 16, 32)
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	payload := make([]byte, int(n)-4)
	_, err = io.ReadFull(r, payload)
	return payload, err
}
func readUntilFlush(r *bufio.Reader) ([][]byte, error) {
	out := [][]byte{}
	for {
		p, err := readPacket(r)
		if err != nil {
			return nil, err
		}
		if p == nil {
			return out, nil
		}
		out = append(out, p)
	}
}
func writePacket(w *bufio.Writer, payload []byte) error {
	if _, err := fmt.Fprintf(w, "%04x", len(payload)+4); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.Write(payload)
	return err
}
func writeFlush(w *bufio.Writer) error {
	_, err := w.WriteString("0000")
	return err
}
func writeSuccess(w *bufio.Writer, data []byte) error {
	if err := writePacket(w, []byte("status=success\n")); err != nil { return err }
	if err := writeFlush(w); err != nil { return err }
	if len(data) > 0 {
		if err := writePacket(w, data); err != nil { return err }
	}
	if err := writeFlush(w); err != nil { return err }
	if err := writePacket(w, []byte("status=success\n")); err != nil { return err }
	if err := writeFlush(w); err != nil { return err }
	return w.Flush()
}
func main() {
	r := bufio.NewReader(os.Stdin)
	w := bufio.NewWriter(os.Stdout)
	if _, err := readUntilFlush(r); err != nil { os.Exit(1) }
	_ = writePacket(w, []byte("git-filter-server\n"))
	_ = writePacket(w, []byte("version=2\n"))
	_ = writeFlush(w)
	_ = w.Flush()
	if _, err := readUntilFlush(r); err != nil { os.Exit(1) }
	_ = writePacket(w, []byte("capability=clean\n"))
	_ = writePacket(w, []byte("capability=smudge\n"))
	_ = writeFlush(w)
	_ = w.Flush()
	for {
		header, err := readUntilFlush(r)
		if err == io.EOF {
			return
		}
		if err != nil {
			os.Exit(1)
		}
		dataFrames, err := readUntilFlush(r)
		if err != nil {
			os.Exit(1)
		}
		if len(header) == 0 {
			continue
		}
		command := ""
		for _, packet := range header {
			line := strings.TrimSpace(string(packet))
			if strings.HasPrefix(line, "command=") {
				command = strings.TrimPrefix(line, "command=")
			}
		}
		data := []byte{}
		for _, frame := range dataFrames {
			data = append(data, frame...)
		}
		if command == "smudge" {
			_ = writeSuccess(w, append([]byte("SMUDGE:"), data...))
			continue
		}
		if command == "clean" {
			_ = writeSuccess(w, append([]byte("CLEAN:"), data...))
			continue
		}
		os.Exit(1)
	}
}
`
	require.NoError(t, os.WriteFile(source, []byte(code), 0o644))
	cmd := exec.Command("go", "build", "-o", bin, source)
	out, err := cmd.CombinedOutput()
	require.NoErrorf(t, err, "failed to build fake git-lfs: %s", string(out))
	return bin
}

// buildFakeGitLFSStderrFloodBinary creates a fake git-lfs that writes >64KB to stderr before replying.
func buildFakeGitLFSStderrFloodBinary(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	source := filepath.Join(dir, "fake_git_lfs_stderr_flood.go")
	bin := filepath.Join(dir, "git-lfs")
	code := `package main
import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)
func readPacket(r *bufio.Reader) ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, err
	}
	n, err := strconv.ParseInt(string(header), 16, 32)
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	payload := make([]byte, int(n)-4)
	_, err = io.ReadFull(r, payload)
	return payload, err
}
func readUntilFlush(r *bufio.Reader) ([][]byte, error) {
	out := [][]byte{}
	for {
		p, err := readPacket(r)
		if err != nil {
			return nil, err
		}
		if p == nil {
			return out, nil
		}
		out = append(out, p)
	}
}
func writePacket(w *bufio.Writer, payload []byte) error {
	if _, err := fmt.Fprintf(w, "%04x", len(payload)+4); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.Write(payload)
	return err
}
func writeFlush(w *bufio.Writer) error {
	_, err := w.WriteString("0000")
	return err
}
func writeSuccess(w *bufio.Writer, data []byte) error {
	if err := writePacket(w, []byte("status=success\n")); err != nil { return err }
	if err := writeFlush(w); err != nil { return err }
	if len(data) > 0 {
		if err := writePacket(w, data); err != nil { return err }
	}
	if err := writeFlush(w); err != nil { return err }
	if err := writePacket(w, []byte("status=success\n")); err != nil { return err }
	if err := writeFlush(w); err != nil { return err }
	return w.Flush()
}
func writeStderrFlood() error {
	_, err := os.Stderr.Write(bytes.Repeat([]byte("e"), 128*1024))
	return err
}
func main() {
	r := bufio.NewReader(os.Stdin)
	w := bufio.NewWriter(os.Stdout)
	if _, err := readUntilFlush(r); err != nil { os.Exit(1) }
	_ = writePacket(w, []byte("git-filter-server\n"))
	_ = writePacket(w, []byte("version=2\n"))
	_ = writeFlush(w)
	_ = w.Flush()
	if _, err := readUntilFlush(r); err != nil { os.Exit(1) }
	_ = writePacket(w, []byte("capability=clean\n"))
	_ = writePacket(w, []byte("capability=smudge\n"))
	_ = writeFlush(w)
	_ = w.Flush()
	for {
		header, err := readUntilFlush(r)
		if err == io.EOF {
			return
		}
		if err != nil {
			os.Exit(1)
		}
		dataFrames, err := readUntilFlush(r)
		if err != nil {
			os.Exit(1)
		}
		if len(header) == 0 {
			continue
		}
		command := ""
		for _, packet := range header {
			line := strings.TrimSpace(string(packet))
			if strings.HasPrefix(line, "command=") {
				command = strings.TrimPrefix(line, "command=")
			}
		}
		data := []byte{}
		for _, frame := range dataFrames {
			data = append(data, frame...)
		}
		if err := writeStderrFlood(); err != nil {
			os.Exit(1)
		}
		if command == "smudge" {
			_ = writeSuccess(w, append([]byte("SMUDGE:"), data...))
			continue
		}
		if command == "clean" {
			_ = writeSuccess(w, append([]byte("CLEAN:"), data...))
			continue
		}
		os.Exit(1)
	}
}
`
	require.NoError(t, os.WriteFile(source, []byte(code), 0o644))
	cmd := exec.Command("go", "build", "-o", bin, source)
	out, err := cmd.CombinedOutput()
	require.NoErrorf(t, err, "failed to build fake git-lfs stderr flood binary: %s", string(out))
	return bin
}
