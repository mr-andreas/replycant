package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/pairing"
	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
	"github.com/mr-andreas/replycant/pkg/tailnetagent"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A 404 is the expected answer until someone approves the device. Anything
// else means discovery itself is wrong and must not be retried into a timeout.
func TestPollPairingRecord(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if hits.Add(1) == 1 {
			http.NotFound(w, nil)
			return
		}
		_, _ = w.Write([]byte("sealed"))
	}))
	t.Cleanup(server.Close)

	body, err := PollPairingRecord(context.Background(), "http://discovery.test", "slot", dialClient(server), 10*time.Millisecond)
	require.NoError(t, err)
	assert.Equal(t, "sealed", string(body))
	assert.GreaterOrEqual(t, hits.Load(), int32(2))
}

func TestPollPairingRecordReportsUnexpectedStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "nope", http.StatusInternalServerError)
	}))
	t.Cleanup(server.Close)

	_, err := PollPairingRecord(context.Background(), "http://discovery.test", "slot", dialClient(server), time.Hour)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "500")
}

func TestPollPairingRecordHonorsCancel(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.NotFound(w, nil)
	}))
	t.Cleanup(server.Close)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := PollPairingRecord(ctx, "http://discovery.test", "slot", dialClient(server), time.Hour)
	require.Error(t, err)
}

// The tailnet coordinates are written only once the node is up. A failed join
// must not leave a config that the next git command would trust.
func TestClonePersistsTailnetConfigOnlyAfterJoin(t *testing.T) {
	putRemoteHelperOnPath(t)
	secret := mustSecret(t)
	dir := filepath.Join(t.TempDir(), "repo")
	caPEM := testCAPEM(t)

	var joined atomic.Bool
	server := pairingServer(t, dir, secret, pairing.Payload{
		HeadscaleURL: "https://headscale.example",
		CAPEM:        caPEM,
		PreauthKey:   "hskey-test",
	})
	err := runClone(CloneOptions{
		Directory:    dir,
		DiscoveryURL: "http://discovery.test",
		NoLFS:        true,
		DeviceName:   "cli",
	}, cloneRuntime{
		pollInterval: 10 * time.Millisecond,
		httpClient:   dialClient(server),
		newSecret:    func() (pairing.Secret, error) { return secret, nil },
		join: func(_ context.Context, _ string, cfg tailnetagent.StartConfig) error {
			assert.Equal(t, "hskey-test", cfg.PreauthKey)
			assert.Equal(t, "headscale.example:443", cfg.HeadscaleAddr)
			joined.Store(true)
			return nil
		},
		finish: func(context.Context, cloneFinish) error { return nil },
	})
	require.NoError(t, err)
	assert.True(t, joined.Load())

	gitDir, err := resolveGitDir(dir)
	require.NoError(t, err)
	cfg, err := tailnetagent.LoadConfig(gitDir)
	require.NoError(t, err)
	assert.Equal(t, "headscale.example:443", cfg.HeadscaleAddr)
	assert.Equal(t, "headscale.example", cfg.HeadscaleServerName)

	ca, err := os.ReadFile(filepath.Join(gitDir, "replycant", "ca.pem"))
	require.NoError(t, err)
	assert.Equal(t, caPEM, string(ca))

	origin := strings.TrimSpace(testRunGit(t, dir, "remote", "get-url", "origin"))
	assert.Equal(t, remoteHelperPrefix+tailnetaddr.GitdURL(), origin)
}

func TestCloneDoesNotPersistConfigWhenJoinFails(t *testing.T) {
	putRemoteHelperOnPath(t)
	secret := mustSecret(t)
	dir := filepath.Join(t.TempDir(), "repo")
	server := pairingServer(t, dir, secret, pairing.Payload{
		HeadscaleURL: "https://headscale.example",
		CAPEM:        "ca",
		PreauthKey:   "hskey-test",
	})
	err := runClone(CloneOptions{
		Directory:    dir,
		DiscoveryURL: "http://discovery.test",
		NoLFS:        true,
	}, cloneRuntime{
		pollInterval: 10 * time.Millisecond,
		httpClient:   dialClient(server),
		newSecret:    func() (pairing.Secret, error) { return secret, nil },
		join: func(context.Context, string, tailnetagent.StartConfig) error {
			return assertErr("join failed")
		},
		finish: func(context.Context, cloneFinish) error {
			t.Fatal("fetch should not run when the tailnet join failed")
			return nil
		},
	})
	require.Error(t, err)

	gitDir, gitErr := resolveGitDir(dir)
	require.NoError(t, gitErr)
	_, loadErr := tailnetagent.LoadConfig(gitDir)
	assert.ErrorIs(t, loadErr, tailnetagent.ErrNotConfigured)
}

// A record whose CA does not match the fingerprint in the headscale hostname
// must be refused before this machine joins that tailnet.
func TestCloneRefusesMismatchedCALabel(t *testing.T) {
	putRemoteHelperOnPath(t)
	secret := mustSecret(t)
	dir := filepath.Join(t.TempDir(), "repo")
	server := pairingServer(t, dir, secret, pairing.Payload{
		HeadscaleURL: "https://0123456789abcdef0123456789abcdef.example.com",
		CAPEM:        testCAPEM(t),
		PreauthKey:   "hskey-test",
	})
	err := runClone(CloneOptions{
		Directory:    dir,
		DiscoveryURL: "http://discovery.test",
		NoLFS:        true,
	}, cloneRuntime{
		pollInterval: 10 * time.Millisecond,
		httpClient:   dialClient(server),
		newSecret:    func() (pairing.Secret, error) { return secret, nil },
		join: func(context.Context, string, tailnetagent.StartConfig) error {
			t.Fatal("refused CA must not join")
			return nil
		},
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "does not match")
}

func pairingServer(t *testing.T, dir string, secret pairing.Secret, payload pairing.Payload) *httptest.Server {
	t.Helper()
	var hits atomic.Int32
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if hits.Add(1) == 1 {
			http.NotFound(w, nil)
			return
		}
		identityPath := filepath.Join(dir, ".git", "replycant", "identity.json")
		raw, err := os.ReadFile(identityPath)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		var identity gitcrypt.Identity
		if err := json.Unmarshal(raw, &identity); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		ageKey, err := gitcrypt.DecodeAgePublicKey(identity.AgePublicKey)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		sealed, err := pairing.Seal(secret, ageKey, payload)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_, _ = w.Write(sealed)
	}))
}

func dialClient(server *httptest.Server) *http.Client {
	return &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
		},
	}}
}

func putRemoteHelperOnPath(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, remoteHelperName)
	require.NoError(t, os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755))
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func mustSecret(t *testing.T) pairing.Secret {
	t.Helper()
	secret, err := pairing.NewSecret()
	require.NoError(t, err)
	return secret
}

func testCAPEM(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "test-ca"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	require.NoError(t, err)
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

type assertErr string

func (e assertErr) Error() string { return string(e) }
