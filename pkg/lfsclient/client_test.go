package lfsclient

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestDeriveEndpointURL forces LFS onto the git origin /lfs route so clients
// never invent a per-repo info/lfs path that would bypass gitd's mTLS proxy.
func TestDeriveEndpointURL(t *testing.T) {
	t.Parallel()
	tests := []struct {
		gitURL string
		want   string
	}{
		{gitURL: "https://example.com/", want: "https://example.com/lfs"},
		{gitURL: "https://example.com/repo.git", want: "https://example.com/lfs"},
		{gitURL: "https://user:pass@example.com:8443/foo", want: "https://example.com:8443/lfs"},
	}
	for _, tt := range tests {
		got, err := DeriveEndpointURL(tt.gitURL)
		require.NoError(t, err, tt.gitURL)
		assert.Equal(t, tt.want, got)
	}
}

// TestParseEndpoint strips embedded Basic credentials into AuthHeader so they
// can be applied on requests without leaking into the request URL.
func TestParseEndpoint(t *testing.T) {
	t.Parallel()
	endpoint, err := ParseEndpoint("https://admin:secret@example.com/lfs")
	require.NoError(t, err)
	assert.Equal(t, "https://example.com/lfs", endpoint.BaseURL.String())
	assert.Equal(t, "Basic YWRtaW46c2VjcmV0", endpoint.AuthHeader)
}

// TestClientUploadHappyPath verifies batch negotiation, PUT upload, and verify
// complete when the server returns both actions.
func TestClientUploadHappyPath(t *testing.T) {
	t.Parallel()
	oid := "2222222222222222222222222222222222222222222222222222222222222222"
	objectBody := []byte("encrypted-object-body")

	var mu sync.Mutex
	uploaded := []byte{}
	verifyCalls := 0
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/objects/batch":
			require.Equal(t, http.MethodPost, r.Method)
			require.Equal(t, "application/vnd.git-lfs+json", r.Header.Get("Accept"))
			require.Equal(t, "application/vnd.git-lfs+json", r.Header.Get("Content-Type"))
			require.Equal(t, "Basic dTpw", r.Header.Get("Authorization"))
			var payload batchRequest
			require.NoError(t, json.NewDecoder(r.Body).Decode(&payload))
			require.Equal(t, "upload", payload.Operation)
			require.NotNil(t, payload.Ref)
			assert.Equal(t, "refs/heads/main", payload.Ref.Name)
			require.Len(t, payload.Objects, 1)
			response := batchResponse{
				Objects: []batchObject{
					{
						OID:  oid,
						Size: int64(len(objectBody)),
						Actions: map[string]batchAction{
							"upload": {
								Href:   server.URL + "/upload/" + oid,
								Header: map[string]string{"X-Upload-Token": "test-upload"},
							},
							"verify": {
								Href:   server.URL + "/verify/" + oid,
								Header: map[string]string{"X-Verify-Token": "test-verify"},
							},
						},
					},
				},
			}
			w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
			require.NoError(t, json.NewEncoder(w).Encode(response))
		case r.URL.Path == "/upload/"+oid:
			require.Equal(t, http.MethodPut, r.Method)
			require.Equal(t, "test-upload", r.Header.Get("X-Upload-Token"))
			body, err := io.ReadAll(r.Body)
			require.NoError(t, err)
			mu.Lock()
			uploaded = append([]byte{}, body...)
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/verify/"+oid:
			require.Equal(t, http.MethodPost, r.Method)
			require.Equal(t, "test-verify", r.Header.Get("X-Verify-Token"))
			var verifyPayload Object
			require.NoError(t, json.NewDecoder(r.Body).Decode(&verifyPayload))
			require.Equal(t, oid, verifyPayload.OID)
			require.EqualValues(t, len(objectBody), verifyPayload.Size)
			mu.Lock()
			verifyCalls++
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	client := &Client{
		HTTP:     server.Client(),
		Endpoint: Endpoint{BaseURL: parsedURL, AuthHeader: "Basic dTpw"},
		Log:      io.Discard,
	}
	err = client.Upload(context.Background(), "refs/heads/main",
		[]Object{{OID: oid, Size: int64(len(objectBody))}},
		func(object Object) (io.ReadCloser, error) {
			return io.NopCloser(bytes.NewReader(objectBody)), nil
		},
	)
	require.NoError(t, err)
	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, objectBody, uploaded)
	assert.Equal(t, 1, verifyCalls)
}

// TestClientUploadHEADFallback covers the lfs-test-server case where batch
// claims the object exists but HEAD proves the bytes are missing.
func TestClientUploadHEADFallback(t *testing.T) {
	t.Parallel()
	oid := "3333333333333333333333333333333333333333333333333333333333333333"
	objectBody := []byte("encrypted-object-body-fallback")

	var mu sync.Mutex
	headCalls := 0
	directPutCalls := 0
	uploaded := []byte{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/objects/batch":
			response := batchResponse{
				Objects: []batchObject{{
					OID:     oid,
					Size:    int64(len(objectBody)),
					Actions: map[string]batchAction{},
				}},
			}
			w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
			require.NoError(t, json.NewEncoder(w).Encode(response))
		case r.URL.Path == "/objects/"+oid && r.Method == http.MethodHead:
			mu.Lock()
			headCalls++
			mu.Unlock()
			w.WriteHeader(http.StatusNotFound)
		case r.URL.Path == "/objects/"+oid && r.Method == http.MethodPut:
			body, err := io.ReadAll(r.Body)
			require.NoError(t, err)
			mu.Lock()
			directPutCalls++
			uploaded = append([]byte{}, body...)
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	client := &Client{HTTP: server.Client(), Endpoint: Endpoint{BaseURL: parsedURL}, Log: io.Discard}
	err = client.Upload(context.Background(), "refs/heads/main",
		[]Object{{OID: oid, Size: int64(len(objectBody))}},
		func(object Object) (io.ReadCloser, error) {
			return io.NopCloser(bytes.NewReader(objectBody)), nil
		},
	)
	require.NoError(t, err)
	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, 1, headCalls)
	assert.Equal(t, 1, directPutCalls)
	assert.Equal(t, objectBody, uploaded)
}

// TestClientUploadSkipsWhenPresent confirms no PUT when HEAD reports the object
// already has content after batch omitted the upload action.
func TestClientUploadSkipsWhenPresent(t *testing.T) {
	t.Parallel()
	oid := "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/objects/batch":
			response := batchResponse{
				Objects: []batchObject{{OID: oid, Size: 1, Actions: map[string]batchAction{}}},
			}
			w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
			require.NoError(t, json.NewEncoder(w).Encode(response))
		case r.Method == http.MethodHead:
			w.WriteHeader(http.StatusOK)
		default:
			t.Fatal("unexpected request", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	client := &Client{HTTP: server.Client(), Endpoint: Endpoint{BaseURL: parsedURL}, Log: io.Discard}
	err = client.Upload(context.Background(), "",
		[]Object{{OID: oid, Size: 1}},
		func(object Object) (io.ReadCloser, error) {
			t.Fatal("open should not be called when object is already present")
			return nil, nil
		},
	)
	require.NoError(t, err)
}

// TestClientUploadObjectError surfaces object-level batch errors to the caller.
func TestClientUploadObjectError(t *testing.T) {
	t.Parallel()
	oid := "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		response := batchResponse{
			Objects: []batchObject{{
				OID:   oid,
				Size:  1,
				Error: &batchError{Code: 404, Message: "not found"},
			}},
		}
		w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
		require.NoError(t, json.NewEncoder(w).Encode(response))
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	client := &Client{HTTP: server.Client(), Endpoint: Endpoint{BaseURL: parsedURL}, Log: io.Discard}
	err = client.Upload(context.Background(), "",
		[]Object{{OID: oid, Size: 1}},
		func(object Object) (io.ReadCloser, error) {
			return io.NopCloser(bytes.NewReader([]byte{1})), nil
		},
	)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

// TestNewMTLSHTTPClient builds a TLS client that carries the repository identity
// so LFS uploads authenticate the same way as git Smart HTTP.
func TestNewMTLSHTTPClient(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	caPath, certPath, keyPath := writeTestMTLSMaterial(t, dir)

	client, err := NewMTLSHTTPClient(caPath, certPath, keyPath)
	require.NoError(t, err)
	transport, ok := client.Transport.(*http.Transport)
	require.True(t, ok)
	require.NotNil(t, transport.TLSClientConfig)
	assert.Len(t, transport.TLSClientConfig.Certificates, 1)
	require.NotNil(t, transport.DialContext)
}

// writeTestMTLSMaterial creates a self-signed cert/key/CA bundle for client construction tests.
func writeTestMTLSMaterial(t *testing.T, dir string) (caPath, certPath, keyPath string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "lfsclient-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	require.NoError(t, err)
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(key)
	require.NoError(t, err)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})

	caPath = filepath.Join(dir, "ca.pem")
	certPath = filepath.Join(dir, "cert.pem")
	keyPath = filepath.Join(dir, "key.pem")
	require.NoError(t, os.WriteFile(caPath, certPEM, 0o644))
	require.NoError(t, os.WriteFile(certPath, certPEM, 0o644))
	require.NoError(t, os.WriteFile(keyPath, keyPEM, 0o600))

	// Sanity-check the material loads before the unit under test uses it.
	_, err = tls.LoadX509KeyPair(certPath, keyPath)
	require.NoError(t, err)
	return caPath, certPath, keyPath
}
