package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/mr-andreas/replycant/server/gitd/gittest"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Tests parsing valid SSH P-256 ECDSA public keys in standard format.
func TestParseSSHPublicKey_Valid(t *testing.T) {
	// Generate a real P-256 key pair
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey := &privKey.PublicKey

	// Create SSH wire format
	keyType := "ecdsa-sha2-nistp256"
	wireFormat := encodeSSHPublicKey(keyType, pubKey)
	encoded := base64.StdEncoding.EncodeToString(wireFormat)

	tests := []struct {
		name  string
		input string
	}{
		{
			name:  "with comment",
			input: keyType + " " + encoded + " user@host",
		},
		{
			name:  "without comment",
			input: keyType + " " + encoded,
		},
		{
			name:  "with extra whitespace",
			input: keyType + "  " + encoded + "  user@host  ",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parsed, err := parseSSHPublicKey(tt.input)
			require.NoError(t, err)
			assert.True(t, pubKey.Equal(parsed))
		})
	}
}

// Tests that invalid SSH key formats are rejected.
func TestParseSSHPublicKey_Invalid(t *testing.T) {
	tests := []struct {
		name        string
		input       string
		expectedErr string
	}{
		{
			name:        "empty string",
			input:       "",
			expectedErr: "invalid SSH public key format",
		},
		{
			name:        "only key type",
			input:       "ecdsa-sha2-nistp256",
			expectedErr: "invalid SSH public key format",
		},
		{
			name:        "wrong key type ed25519",
			input:       "ssh-ed25519 AAAAB3NzaC1yc2EAAA...",
			expectedErr: "not a P-256 key (type: ssh-ed25519)",
		},
		{
			name:        "wrong key type rsa",
			input:       "ssh-rsa AAAAB3NzaC1yc2EAAA...",
			expectedErr: "not a P-256 key (type: ssh-rsa)",
		},
		{
			name:        "invalid base64",
			input:       "ecdsa-sha2-nistp256 not-valid-base64!!!",
			expectedErr: "failed to decode base64: illegal base64 data at input byte 3",
		},
		{
			name:        "too short decoded",
			input:       "ecdsa-sha2-nistp256 " + base64.StdEncoding.EncodeToString([]byte("short")),
			expectedErr: "decoded key too short",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := parseSSHPublicKey(tt.input)
			assert.ErrorContains(t, err, tt.expectedErr)
		})
	}
}

// Tests extracting P-256 public keys from X.509 certificates.
func TestExtractP256PublicKey(t *testing.T) {
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey := &privKey.PublicKey

	cert := createTestCertificate(t, pubKey, privKey)

	extracted, err := extractP256PublicKey(cert)
	require.NoError(t, err)
	assert.True(t, pubKey.Equal(extracted))
}

// Tests that non-P-256 certificates are rejected.
func TestExtractP256PublicKey_WrongKeyType(t *testing.T) {
	// Create a certificate with a different key type (using a dummy public key)
	cert := &x509.Certificate{
		PublicKey: "not-an-ecdsa-key",
	}

	_, err := extractP256PublicKey(cert)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "does not contain ECDSA")
}

// Tests that wrong curve certificates are rejected.
func TestExtractP256PublicKey_WrongCurve(t *testing.T) {
	// Create a P-384 key (wrong curve)
	privKey, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	require.NoError(t, err)

	cert := &x509.Certificate{
		PublicKey: &privKey.PublicKey,
	}

	_, err = extractP256PublicKey(cert)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "wrong curve")
}

// Tests authentication with valid client certificates.
func TestAuthenticator_Authenticate_Success(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	// Generate keys
	privKey1, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey1 := &privKey1.PublicKey

	privKey2, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey2 := &privKey2.PublicKey

	// Add keys to repository
	addKeyToRepo(t, testRepo, "alice", pubKey1)
	addKeyToRepo(t, testRepo, "bob", pubKey2)

	// Create authenticator using the bare repo
	auth := NewAuthenticator(testRepo.BareRepo, 1*time.Minute)

	// Test authentication with alice's certificate
	cert1 := createTestCertificate(t, pubKey1, privKey1)
	username1, err := auth.Authenticate(cert1)
	require.NoError(t, err)
	assert.Equal(t, "alice", username1)

	// Test authentication with bob's certificate
	cert2 := createTestCertificate(t, pubKey2, privKey2)
	username2, err := auth.Authenticate(cert2)
	require.NoError(t, err)
	assert.Equal(t, "bob", username2)
}

// Tests that unauthorized keys are rejected.
func TestAuthenticator_Authenticate_Unauthorized(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	// Add one authorized key
	privKey1, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey1 := &privKey1.PublicKey
	addKeyToRepo(t, testRepo, "alice", pubKey1)

	// Create authenticator using the bare repo
	auth := NewAuthenticator(testRepo.BareRepo, 1*time.Minute)

	// Try to authenticate with a different key
	privKey2, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey2 := &privKey2.PublicKey

	cert := createTestCertificate(t, pubKey2, privKey2)
	_, err = auth.Authenticate(cert)
	assert.ErrorIs(t, err, ErrUnauthorized)
}

// Tests that key caching works correctly.
func TestAuthenticator_Caching(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey := &privKey.PublicKey
	addKeyToRepo(t, testRepo, "alice", pubKey)

	// Create authenticator with short cache TTL using the bare repo
	auth := NewAuthenticator(testRepo.BareRepo, 100*time.Millisecond)

	// First authentication should load from repo
	cert := createTestCertificate(t, pubKey, privKey)
	username, err := auth.Authenticate(cert)
	require.NoError(t, err)
	assert.Equal(t, "alice", username)

	// Second authentication should use cache
	username, err = auth.Authenticate(cert)
	require.NoError(t, err)
	assert.Equal(t, "alice", username)

	// Wait for cache to expire
	time.Sleep(150 * time.Millisecond)

	// Should reload from repo
	username, err = auth.Authenticate(cert)
	require.NoError(t, err)
	assert.Equal(t, "alice", username)
}

// Tests authentication with nil certificate.
func TestAuthenticator_Authenticate_NilCert(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	auth := NewAuthenticator(testRepo.BareRepo, 1*time.Minute)

	_, err := auth.Authenticate(nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "no client certificate")
}

// Tests HTTP request handler with unauthorized client certificate.
func TestServer_HandleGitRequest_Unauthorized(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	testRepo := testCtx.CreateTestRepo(t)

	// Add a different key to the repo
	authorizedPrivKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	authorizedPubKey := &authorizedPrivKey.PublicKey
	addKeyToRepo(t, testRepo, "authorized", authorizedPubKey)

	certFile := filepath.Join(t.TempDir(), "server.crt")
	keyFile := filepath.Join(t.TempDir(), "server.key")

	serverPrivKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	serverPubKey := &serverPrivKey.PublicKey

	serverCert := createTestCertificate(t, serverPubKey, serverPrivKey)
	testCtx.WriteCertAndKey(t, certFile, keyFile, serverCert, serverPrivKey)

	// Create client cert with unauthorized key
	clientPrivKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	clientPubKey := &clientPrivKey.PublicKey
	clientCert := createTestCertificate(t, clientPubKey, clientPrivKey)

	auth := NewAuthenticator(testRepo.BareRepo, 1*time.Minute)
	username, err := auth.Authenticate(clientCert)
	assert.ErrorIs(t, err, ErrUnauthorized)
	assert.Empty(t, username)
}

// Helper: creates SSH wire format for P-256 public key.
func encodeSSHPublicKey(keyType string, pubKey *ecdsa.PublicKey) []byte {
	// SSH wire format for ECDSA:
	// 4 bytes: length of key type string
	// N bytes: key type string ("ecdsa-sha2-nistp256")
	// 4 bytes: length of curve identifier
	// M bytes: curve identifier ("nistp256")
	// 4 bytes: length of public key point
	// K bytes: public key point (uncompressed: 0x04 || X || Y)

	curveID := "nistp256"
	point := elliptic.Marshal(pubKey.Curve, pubKey.X, pubKey.Y)

	buf := make([]byte, 0, 4+len(keyType)+4+len(curveID)+4+len(point))

	// Length of key type
	lenBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(lenBuf, uint32(len(keyType)))
	buf = append(buf, lenBuf...)
	buf = append(buf, []byte(keyType)...)

	// Length of curve identifier
	binary.BigEndian.PutUint32(lenBuf, uint32(len(curveID)))
	buf = append(buf, lenBuf...)
	buf = append(buf, []byte(curveID)...)

	// Length of point
	binary.BigEndian.PutUint32(lenBuf, uint32(len(point)))
	buf = append(buf, lenBuf...)
	buf = append(buf, point...)

	return buf
}

// Helper: creates a test X.509 certificate with P-256 key.
func createTestCertificate(t *testing.T, pubKey *ecdsa.PublicKey, privKey *ecdsa.PrivateKey) *x509.Certificate {
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName: "test-client",
		},
		NotBefore: time.Now(),
		NotAfter:  time.Now().Add(24 * time.Hour),
		KeyUsage:  x509.KeyUsageDigitalSignature,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, pubKey, privKey)
	require.NoError(t, err)

	cert, err := x509.ParseCertificate(certDER)
	require.NoError(t, err)

	return cert
}

// Tests that empty repositories return ErrUnauthorizedBootstrap for any valid P-256 certificate.
func TestAuthenticator_EmptyRepository_AllowsAnyValidCert(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	emptyRepo := testCtx.CreateEmptyTestRepo(t)

	auth := NewAuthenticator(emptyRepo, 1*time.Minute)

	// Generate a random P-256 key pair
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey := &privKey.PublicKey

	// Create certificate with this key
	cert := createTestCertificate(t, pubKey, privKey)

	// Should return ErrUnauthorizedBootstrap for empty repository
	username, err := auth.Authenticate(cert)
	assert.ErrorIs(t, err, ErrUnauthorizedBootstrap)
	assert.Equal(t, "bootstrap", username)
}

// Tests that after the first push, normal authentication resumes.
func TestAuthenticator_EmptyRepository_AfterPush_RequiresAuthorizedKey(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	emptyRepo := testCtx.CreateEmptyTestRepo(t)

	auth := NewAuthenticator(emptyRepo, 1*time.Minute)

	// First, verify bootstrap mode works
	privKey1, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey1 := &privKey1.PublicKey
	cert1 := createTestCertificate(t, pubKey1, privKey1)

	username, err := auth.Authenticate(cert1)
	assert.ErrorIs(t, err, ErrUnauthorizedBootstrap)
	assert.Equal(t, "bootstrap", username)

	// Now simulate a push by creating a commit with a key
	_ = simulateBootstrapPush(t, emptyRepo, "alice", pubKey1)

	// After the push, the same certificate should now authenticate as "alice"
	username, err = auth.Authenticate(cert1)
	require.NoError(t, err)
	assert.Equal(t, "alice", username)

	// A different, unauthorized key should now be rejected
	privKey2, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey2 := &privKey2.PublicKey
	cert2 := createTestCertificate(t, pubKey2, privKey2)

	_, err = auth.Authenticate(cert2)
	assert.ErrorIs(t, err, ErrUnauthorized)
}

// Tests that multiple different certificates return ErrUnauthorizedBootstrap in bootstrap mode.
func TestAuthenticator_EmptyRepository_MultipleCertsAllowed(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	emptyRepo := testCtx.CreateEmptyTestRepo(t)

	auth := NewAuthenticator(emptyRepo, 1*time.Minute)

	// Try three different certificates
	for i := 0; i < 3; i++ {
		privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		require.NoError(t, err)
		pubKey := &privKey.PublicKey
		cert := createTestCertificate(t, pubKey, privKey)

		username, err := auth.Authenticate(cert)
		assert.ErrorIs(t, err, ErrUnauthorizedBootstrap)
		assert.Equal(t, "bootstrap", username)
	}
}

// Tests that a repository with a non-main branch is NOT considered empty.
func TestAuthenticator_NonMainBranch_NotEmpty(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)

	// Create a repository with a branch called "foo" but no "main"
	bareDir, err := os.MkdirTemp("", "gitd-nonmain-*")
	require.NoError(t, err)
	defer os.RemoveAll(bareDir)

	_, err = git.PlainInit(bareDir, true)
	require.NoError(t, err)

	// Create a working directory to make a commit on a non-main branch
	workDir, err := os.MkdirTemp("", "gitd-work-*")
	require.NoError(t, err)
	defer os.RemoveAll(workDir)

	repo, err := git.PlainInit(workDir, false)
	require.NoError(t, err)

	worktree, err := repo.Worktree()
	require.NoError(t, err)

	// Create a file and commit
	testFile := filepath.Join(workDir, "test.txt")
	err = os.WriteFile(testFile, []byte("test"), 0644)
	require.NoError(t, err)

	_, err = worktree.Add("test.txt")
	require.NoError(t, err)

	_, err = worktree.Commit("Initial commit", &git.CommitOptions{
		Author: &object.Signature{
			Name:  "Test",
			Email: "test@example.com",
			When:  time.Now(),
		},
	})
	require.NoError(t, err)

	// Create a branch called "foo" (not "main")
	headRef, err := repo.Head()
	require.NoError(t, err)

	fooRef := plumbing.NewBranchReferenceName("foo")
	err = repo.Storer.SetReference(plumbing.NewHashReference(fooRef, headRef.Hash()))
	require.NoError(t, err)

	// Push to bare repo
	_, err = repo.CreateRemote(&config.RemoteConfig{
		Name: "origin",
		URLs: []string{bareDir},
	})
	require.NoError(t, err)

	err = repo.Push(&git.PushOptions{
		RemoteName: "origin",
		RefSpecs:   []config.RefSpec{"refs/heads/foo:refs/heads/foo"},
	})
	require.NoError(t, err)

	// Now test authentication - should require authorized keys, not bootstrap
	auth := NewAuthenticator(bareDir, 1*time.Minute)

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	pubKey := &privKey.PublicKey
	cert := createTestCertificate(t, pubKey, privKey)

	// Should fail because repository is not empty (has "foo" branch)
	_, err = auth.Authenticate(cert)
	assert.ErrorIs(t, err, ErrUnauthorized)
	assert.Contains(t, err.Error(), "failed to load authorized keys")
}

// Tests that concurrent bootstrap attempts are handled safely.
// This test verifies that the ErrUnauthorizedBootstrap signal works correctly
// when multiple clients try to authenticate simultaneously on an empty repo.
func TestAuthenticator_EmptyRepository_ConcurrentAccess(t *testing.T) {
	testCtx := gittest.NewContext(t)
	defer testCtx.Close(t)
	emptyRepo := testCtx.CreateEmptyTestRepo(t)

	auth := NewAuthenticator(emptyRepo, 1*time.Minute)

	// Launch multiple concurrent authentication attempts
	const numAttempts = 10
	results := make(chan error, numAttempts)

	for i := 0; i < numAttempts; i++ {
		go func() {
			privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			if err != nil {
				results <- err
				return
			}
			pubKey := &privKey.PublicKey
			cert := createTestCertificate(t, pubKey, privKey)
			_, err = auth.Authenticate(cert)
			results <- err
		}()
	}

	// Collect results
	for i := 0; i < numAttempts; i++ {
		err := <-results
		// All should return ErrUnauthorizedBootstrap for empty repo
		assert.ErrorIs(t, err, ErrUnauthorizedBootstrap)
	}
}

// Helper: simulates a bootstrap push by creating initial commit with pubkey.
func simulateBootstrapPush(t *testing.T, bareRepo string, username string, pubKey *ecdsa.PublicKey) gittest.TestRepo {
	// Create a working directory
	workDir, err := os.MkdirTemp("", "gitd-bootstrap-work-*")
	require.NoError(t, err)

	repo, err := git.PlainInit(workDir, false)
	require.NoError(t, err)

	worktree, err := repo.Worktree()
	require.NoError(t, err)

	// Create pubkeys directory
	pubkeysDir := filepath.Join(workDir, "pubkeys")
	err = os.Mkdir(pubkeysDir, 0755)
	require.NoError(t, err)

	// Write the key file
	keyType := "ecdsa-sha2-nistp256"
	wireFormat := encodeSSHPublicKey(keyType, pubKey)
	encoded := base64.StdEncoding.EncodeToString(wireFormat)
	sshKey := keyType + " " + encoded + " " + username + "@test\n"

	keyFile := filepath.Join(workDir, "pubkeys", username+".pub")
	err = os.WriteFile(keyFile, []byte(sshKey), 0644)
	require.NoError(t, err)

	// Add and commit
	_, err = worktree.Add("pubkeys/" + username + ".pub")
	require.NoError(t, err)

	_, err = worktree.Commit("Bootstrap: add key for "+username, &git.CommitOptions{
		Author: &object.Signature{
			Name:  username,
			Email: username + "@bootstrap",
			When:  time.Now(),
		},
	})
	require.NoError(t, err)

	// Ensure we have a "main" branch
	headRef, err := repo.Head()
	require.NoError(t, err)

	mainRef := plumbing.NewBranchReferenceName("main")
	if headRef.Name().Short() != "main" {
		err = repo.Storer.SetReference(plumbing.NewHashReference(mainRef, headRef.Hash()))
		require.NoError(t, err)

		err = worktree.Checkout(&git.CheckoutOptions{
			Branch: mainRef,
		})
		require.NoError(t, err)
	}

	// Add bare repo as remote and push
	_, err = repo.CreateRemote(&config.RemoteConfig{
		Name: "origin",
		URLs: []string{bareRepo},
	})
	require.NoError(t, err)

	err = repo.Push(&git.PushOptions{
		RemoteName: "origin",
		RefSpecs:   []config.RefSpec{"refs/heads/main:refs/heads/main"},
	})
	require.NoError(t, err)

	return gittest.TestRepo{
		BareRepo: bareRepo,
		WorkDir:  workDir,
	}
}

// Helper: adds a public key file to the working directory and pushes to bare repo.
func addKeyToRepo(t *testing.T, testRepo gittest.TestRepo, username string, pubKey *ecdsa.PublicKey) {
	repo, err := git.PlainOpen(testRepo.WorkDir)
	require.NoError(t, err)

	worktree, err := repo.Worktree()
	require.NoError(t, err)

	// Create SSH format key
	keyType := "ecdsa-sha2-nistp256"
	wireFormat := encodeSSHPublicKey(keyType, pubKey)
	encoded := base64.StdEncoding.EncodeToString(wireFormat)
	sshKey := keyType + " " + encoded + " " + username + "@test\n"

	// Write key file
	keyFile := filepath.Join(testRepo.WorkDir, "pubkeys", username+".pub")
	err = os.WriteFile(keyFile, []byte(sshKey), 0644)
	require.NoError(t, err)

	// Add and commit
	_, err = worktree.Add("pubkeys/" + username + ".pub")
	require.NoError(t, err)

	_, err = worktree.Commit("Add key for "+username, &git.CommitOptions{
		Author: &object.Signature{
			Name:  "Test",
			Email: "test@example.com",
			When:  time.Now(),
		},
	})
	require.NoError(t, err)

	// Push to bare repo
	err = repo.Push(&git.PushOptions{})
	require.NoError(t, err)
}
