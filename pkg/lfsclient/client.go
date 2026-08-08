package lfsclient

import (
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
	"strings"
	"time"

	"github.com/mr-andreas/replycant/pkg/mdns"
)

// Endpoint stores an LFS base URL and optional Basic auth derived from userinfo.
type Endpoint struct {
	BaseURL    *url.URL
	AuthHeader string
}

// Object describes one LFS object that may need uploading.
type Object struct {
	OID  string `json:"oid"`
	Size int64  `json:"size"`
}

// OpenFunc returns a fresh readable body for one object so retries and redirects
// can re-open the payload instead of relying on a one-shot reader.
type OpenFunc func(object Object) (io.ReadCloser, error)

// Client uploads missing LFS objects through the batch API.
type Client struct {
	HTTP     *http.Client
	Endpoint Endpoint
	// Log receives diagnostic lines for long-running uploads; nil discards them.
	Log io.Writer
}

type batchRequest struct {
	Operation string            `json:"operation"`
	Transfers []string          `json:"transfers,omitempty"`
	Ref       *batchRequestRef  `json:"ref,omitempty"`
	Objects   []Object          `json:"objects"`
}

type batchRequestRef struct {
	Name string `json:"name"`
}

type batchResponse struct {
	Transfer string        `json:"transfer"`
	Objects  []batchObject `json:"objects"`
	Message  string        `json:"message"`
}

type batchObject struct {
	OID     string                  `json:"oid"`
	Size    int64                   `json:"size"`
	Actions map[string]batchAction  `json:"actions"`
	Error   *batchError             `json:"error"`
}

type batchAction struct {
	Href   string            `json:"href"`
	Header map[string]string `json:"header"`
}

type batchError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// DeriveEndpointURL forces LFS traffic onto the same origin as git via /lfs.
func DeriveEndpointURL(gitURL string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(gitURL))
	if err != nil {
		return "", fmt.Errorf("invalid git URL %q: %w", strings.TrimSpace(gitURL), err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("invalid git URL %q", strings.TrimSpace(gitURL))
	}
	parsed.User = nil
	parsed.Path = "/lfs"
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}

// ParseEndpoint parses an LFS URL and extracts Basic auth when credentials are embedded.
func ParseEndpoint(rawURL string) (Endpoint, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return Endpoint{}, fmt.Errorf("invalid lfs url %q: %w", strings.TrimSpace(rawURL), err)
	}
	if strings.TrimSpace(parsed.Scheme) == "" || strings.TrimSpace(parsed.Host) == "" {
		return Endpoint{}, fmt.Errorf("invalid lfs url %q", strings.TrimSpace(rawURL))
	}
	authHeader := ""
	if parsed.User != nil {
		username := parsed.User.Username()
		password, _ := parsed.User.Password()
		token := base64.StdEncoding.EncodeToString([]byte(username + ":" + password))
		authHeader = "Basic " + token
		parsed.User = nil
	}
	return Endpoint{BaseURL: parsed, AuthHeader: authHeader}, nil
}

// NewMTLSHTTPClient builds an HTTP client that presents the repository client
// certificate so LFS requests authenticate the same way as git Smart HTTP.
func NewMTLSHTTPClient(caPath, certPath, keyPath string) (*http.Client, error) {
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

// Upload negotiates batch actions then sends missing object bytes through open.
func (c *Client) Upload(ctx context.Context, refName string, objects []Object, open OpenFunc) error {
	if len(objects) == 0 {
		return nil
	}
	if c.HTTP == nil {
		return fmt.Errorf("lfs client HTTP is required")
	}
	if open == nil {
		return fmt.Errorf("lfs open function is required")
	}
	parsed, err := c.sendBatchRequest(ctx, refName, objects)
	if err != nil {
		return err
	}
	expected := map[string]Object{}
	for _, object := range objects {
		expected[object.OID] = object
	}
	for _, object := range parsed.Objects {
		expectedObject, ok := expected[object.OID]
		if !ok {
			continue
		}
		if err := c.processBatchObject(ctx, expectedObject, object, open); err != nil {
			return err
		}
	}
	return nil
}

func (c *Client) logf(format string, args ...any) {
	if c.Log == nil {
		return
	}
	fmt.Fprintf(c.Log, format, args...)
}

func (c *Client) sendBatchRequest(ctx context.Context, refName string, objects []Object) (*batchResponse, error) {
	batchURL := *c.Endpoint.BaseURL
	batchURL.Path = strings.TrimSuffix(batchURL.Path, "/") + "/objects/batch"
	batchURL.RawQuery = ""
	batchURL.Fragment = ""
	c.logf("lfsclient: batch_request endpoint=%s objects=%d ref=%q\n",
		batchURL.String(), len(objects), strings.TrimSpace(refName))

	reqPayload := batchRequest{
		Operation: "upload",
		Transfers: []string{"basic"},
		Objects:   objects,
	}
	if strings.TrimSpace(refName) != "" {
		reqPayload.Ref = &batchRequestRef{Name: refName}
	}
	body, err := json.Marshal(reqPayload)
	if err != nil {
		return nil, fmt.Errorf("failed encoding lfs batch request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, batchURL.String(), bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("failed creating lfs batch request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.git-lfs+json")
	req.Header.Set("Content-Type", "application/vnd.git-lfs+json")
	if c.Endpoint.AuthHeader != "" {
		req.Header.Set("Authorization", c.Endpoint.AuthHeader)
	}
	timeoutCtx, cancel := context.WithTimeout(ctx, 600*time.Second)
	defer cancel()
	req = req.WithContext(timeoutCtx)
	resp, err := c.HTTP.Do(req)
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
	c.logf("lfsclient: batch_response status=%d\n", resp.StatusCode)

	var parsed batchResponse
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return nil, fmt.Errorf("failed decoding lfs batch response: %w", err)
	}
	c.logf("lfsclient: batch_objects=%d transfer=%q\n",
		len(parsed.Objects), strings.TrimSpace(parsed.Transfer))
	return &parsed, nil
}

func (c *Client) processBatchObject(ctx context.Context, expected Object, batchObj batchObject, open OpenFunc) error {
	if batchObj.Error != nil {
		return fmt.Errorf("lfs object %s failed with code %d: %s",
			batchObj.OID, batchObj.Error.Code, strings.TrimSpace(batchObj.Error.Message))
	}
	uploadAction, hasUpload := batchObj.Actions["upload"]
	if !hasUpload {
		// Temporary compatibility fallback for lfs-test-server: batch can report an
		// object as present via metadata while object bytes are still missing.
		exists, err := c.headCheckObjectExists(ctx, batchObj.OID)
		if err != nil {
			return err
		}
		if exists {
			c.logf("lfsclient: object %s verified present via HEAD; skipping upload\n", batchObj.OID)
			return nil
		}
		c.logf("lfsclient: object %s batch-reported present but missing via HEAD; uploading directly\n",
			batchObj.OID)
		directAction := batchAction{
			Href: c.buildObjectURL(batchObj.OID),
			Header: map[string]string{
				"Accept": "application/vnd.git-lfs",
			},
		}
		if err := c.uploadOne(ctx, expected, directAction, open); err != nil {
			return err
		}
		c.logf("lfsclient: uploaded oid=%s via direct fallback\n", expected.OID)
		return nil
	}
	c.logf("lfsclient: uploading oid=%s size=%d\n", expected.OID, expected.Size)
	if err := c.uploadOne(ctx, expected, uploadAction, open); err != nil {
		return err
	}
	c.logf("lfsclient: uploaded oid=%s\n", expected.OID)
	if verifyAction, hasVerify := batchObj.Actions["verify"]; hasVerify {
		c.logf("lfsclient: verifying oid=%s\n", expected.OID)
		if err := c.verifyOne(ctx, expected, verifyAction); err != nil {
			return err
		}
		c.logf("lfsclient: verified oid=%s\n", expected.OID)
	}
	return nil
}

func (c *Client) uploadOne(ctx context.Context, object Object, action batchAction, open OpenFunc) error {
	body, err := open(object)
	if err != nil {
		return fmt.Errorf("failed opening lfs object %s: %w", object.OID, err)
	}
	defer body.Close()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, action.Href, body)
	if err != nil {
		return fmt.Errorf("failed creating upload request for %s: %w", object.OID, err)
	}
	req.ContentLength = object.Size
	applyActionHeaders(req, action.Header)
	if c.Endpoint.AuthHeader != "" && req.Header.Get("Authorization") == "" {
		req.Header.Set("Authorization", c.Endpoint.AuthHeader)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("failed uploading lfs object %s: %w", object.OID, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed uploading lfs object %s: status %d: %s",
			object.OID, resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	return nil
}

func (c *Client) verifyOne(ctx context.Context, object Object, action batchAction) error {
	payload, err := json.Marshal(Object{OID: object.OID, Size: object.Size})
	if err != nil {
		return fmt.Errorf("failed encoding verify request for %s: %w", object.OID, err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, action.Href, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("failed creating verify request for %s: %w", object.OID, err)
	}
	req.Header.Set("Accept", "application/vnd.git-lfs+json")
	req.Header.Set("Content-Type", "application/vnd.git-lfs+json")
	applyActionHeaders(req, action.Header)
	if c.Endpoint.AuthHeader != "" && req.Header.Get("Authorization") == "" {
		req.Header.Set("Authorization", c.Endpoint.AuthHeader)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("failed verifying lfs object %s: %w", object.OID, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed verifying lfs object %s: status %d: %s",
			object.OID, resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	return nil
}

func (c *Client) headCheckObjectExists(ctx context.Context, oid string) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, c.buildObjectURL(oid), nil)
	if err != nil {
		return false, fmt.Errorf("failed creating head request for %s: %w", oid, err)
	}
	req.Header.Set("Accept", "application/vnd.git-lfs")
	if c.Endpoint.AuthHeader != "" {
		req.Header.Set("Authorization", c.Endpoint.AuthHeader)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return false, fmt.Errorf("failed checking lfs object %s via head: %w", oid, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1))
	return resp.StatusCode >= 200 && resp.StatusCode < 300, nil
}

func (c *Client) buildObjectURL(oid string) string {
	objectURL := *c.Endpoint.BaseURL
	objectURL.Path = strings.TrimSuffix(objectURL.Path, "/") + "/objects/" + oid
	objectURL.RawQuery = ""
	objectURL.Fragment = ""
	return objectURL.String()
}

func applyActionHeaders(req *http.Request, headers map[string]string) {
	for key, value := range headers {
		if strings.TrimSpace(key) == "" {
			continue
		}
		req.Header.Set(key, value)
	}
}
