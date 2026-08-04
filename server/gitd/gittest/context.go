package gittest

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/stretchr/testify/require"
)

// Manages test repository lifecycle and cleanup.
type Context struct {
	createdDirs []string
}

// Holds paths to bare repository and its working clone.
// BareRepo is used by the server, WorkDir is used to make modifications.
type TestRepo struct {
	BareRepo string
	WorkDir  string
}

func NewContext(t testing.TB) *Context {
	return &Context{}
}

func (c *Context) Close(t *testing.T) {
	for _, dir := range c.createdDirs {
		os.RemoveAll(dir)
	}
}

// Creates a completely empty bare git repository for testing bootstrap authentication.
// Unlike CreateTestRepo, this repository has no commits, branches, or refs.
func (c *Context) CreateEmptyTestRepo(t *testing.T) string {
	bareDir, err := os.MkdirTemp("", "gitd-empty-bare-*")
	require.NoError(t, err)
	c.createdDirs = append(c.createdDirs, bareDir)

	_, err = git.PlainInit(bareDir, true)
	require.NoError(t, err)

	return bareDir
}

// Creates a bare git repository and a working clone for test modifications.
// Returns paths to both: use BareRepo for server config, WorkDir for file changes.
func (c *Context) CreateTestRepo(t *testing.T) TestRepo {
	// Create the bare repository
	bareDir, err := os.MkdirTemp("", "gitd-bare-*")
	require.NoError(t, err)
	c.createdDirs = append(c.createdDirs, bareDir)

	_, err = git.PlainInit(bareDir, true)
	require.NoError(t, err)

	// Create a working directory clone to set up initial content
	workDir, err := os.MkdirTemp("", "gitd-work-*")
	require.NoError(t, err)
	c.createdDirs = append(c.createdDirs, workDir)

	repo, err := git.PlainInit(workDir, false)
	require.NoError(t, err)

	worktree, err := repo.Worktree()
	require.NoError(t, err)

	// Create pubkeys directory
	pubkeysDir := filepath.Join(workDir, "pubkeys")
	err = os.Mkdir(pubkeysDir, 0755)
	require.NoError(t, err)

	// Create a dummy file to make the initial commit
	dummyFile := filepath.Join(workDir, "README.md")
	err = os.WriteFile(dummyFile, []byte("# Test Repo\n"), 0644)
	require.NoError(t, err)

	_, err = worktree.Add("README.md")
	require.NoError(t, err)

	_, err = worktree.Commit("Initial commit", &git.CommitOptions{
		Author: &object.Signature{
			Name:  "Test",
			Email: "test@example.com",
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
		URLs: []string{bareDir},
	})
	require.NoError(t, err)

	err = repo.Push(&git.PushOptions{
		RemoteName: "origin",
		RefSpecs:   []config.RefSpec{"refs/heads/main:refs/heads/main"},
	})
	require.NoError(t, err)

	return TestRepo{
		BareRepo: bareDir,
		WorkDir:  workDir,
	}
}

// Helper: writes certificate and private key to PEM files.
func (c *Context) WriteCertAndKey(t *testing.T, certFile, keyFile string, cert *x509.Certificate, privKey *ecdsa.PrivateKey) {
	// Write certificate
	certPEM, err := x509.MarshalPKIXPublicKey(cert.PublicKey)
	require.NoError(t, err)
	err = os.WriteFile(certFile, certPEM, 0644)
	require.NoError(t, err)

	// Write private key
	privKeyBytes, err := x509.MarshalPKCS8PrivateKey(privKey)
	require.NoError(t, err)
	err = os.WriteFile(keyFile, privKeyBytes, 0600)
	require.NoError(t, err)
}

// Helper: creates a test X.509 certificate with P-256 ECDSA key.
func (c *Context) CreateTestCertificate(t *testing.T, pubKey *ecdsa.PublicKey, privKey *ecdsa.PrivateKey) *x509.Certificate {
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
