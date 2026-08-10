package gitd

import (
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Public route prefixes for the backend services gitd fronts. Keeping every
// media service behind gitd means devices only ever trust one mTLS endpoint,
// and the backends themselves never need to be reachable from the network.
const (
	decryptdProxyPathPrefix   = "/decryptd"
	transcodedProxyPathPrefix = "/transcoded"
)

// Represents one authenticated reverse-proxy route. Parsed upstream state is
// resolved once at startup so per-request work stays limited to path rewriting.
type serviceProxy struct {
	pathPrefix       string
	upstreamBaseURL  *url.URL
	upstreamAuth     string
	upstreamPathBase string
	httpClient       *http.Client
}

// Parses a configured upstream URL and normalizes it for authenticated proxying.
// Returns a nil proxy for an empty URL so tests and partial deployments can omit
// services they do not exercise.
func newServiceProxy(pathPrefix string, rawURL string) (*serviceProxy, error) {
	trimmed := strings.TrimSpace(rawURL)
	if trimmed == "" {
		return nil, nil
	}

	parsed, err := url.Parse(trimmed)
	if err != nil {
		return nil, fmt.Errorf("parse %s url: %w", strings.TrimPrefix(pathPrefix, "/"), err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return nil, fmt.Errorf("invalid %s url: %q", strings.TrimPrefix(pathPrefix, "/"), rawURL)
	}

	// Credentials live in the upstream URL so they stay server-side; client
	// devices authenticate with mTLS and never see them.
	authHeader := ""
	if parsed.User != nil {
		username := parsed.User.Username()
		password, _ := parsed.User.Password()
		token := base64.StdEncoding.EncodeToString([]byte(username + ":" + password))
		authHeader = "Basic " + token
		parsed.User = nil
	}

	basePath := strings.TrimSuffix(parsed.Path, "/")
	if basePath == "/" {
		basePath = ""
	}

	return &serviceProxy{
		pathPrefix:       pathPrefix,
		upstreamBaseURL:  parsed,
		upstreamAuth:     authHeader,
		upstreamPathBase: basePath,
		httpClient:       &http.Client{Timeout: 5 * time.Minute},
	}, nil
}

// Reports whether this proxy owns the request path.
func (p *serviceProxy) matches(path string) bool {
	return path == p.pathPrefix || strings.HasPrefix(path, p.pathPrefix+"/")
}

// Forwards an authenticated call to the upstream service while preserving
// streaming semantics, which media playback depends on for range requests.
func (s *Server) proxyToService(proxy *serviceProxy, w http.ResponseWriter, r *http.Request) error {
	targetURL, err := proxy.resolveUpstreamURL(r.URL.Path, r.URL.RawQuery)
	if err != nil {
		return err
	}

	upstreamReq, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL.String(), r.Body)
	if err != nil {
		return fmt.Errorf("build upstream request: %w", err)
	}
	copyProxyRequestHeaders(upstreamReq.Header, r.Header)
	if proxy.upstreamAuth != "" {
		upstreamReq.Header.Set("Authorization", proxy.upstreamAuth)
	}

	upstreamRes, err := proxy.httpClient.Do(upstreamReq)
	if err != nil {
		return fmt.Errorf("request upstream: %w", err)
	}
	defer upstreamRes.Body.Close()

	copyProxyResponseHeaders(w.Header(), upstreamRes.Header)
	w.WriteHeader(upstreamRes.StatusCode)
	_, err = io.Copy(w, upstreamRes.Body)
	return err
}

// Resolves an incoming prefixed path to the equivalent upstream endpoint path.
func (p *serviceProxy) resolveUpstreamURL(requestPath string, rawQuery string) (*url.URL, error) {
	if !p.matches(requestPath) {
		return nil, fmt.Errorf("invalid %s proxy path: %q", p.pathPrefix, requestPath)
	}

	suffix := strings.TrimPrefix(requestPath, p.pathPrefix)
	if suffix == "" {
		suffix = "/"
	}

	target := *p.upstreamBaseURL
	target.Path = joinURLPath(p.upstreamBaseURL.Path, suffix)
	target.RawQuery = rawQuery
	target.Fragment = ""
	return &target, nil
}

// Copies request headers while excluding hop-by-hop values unsafe for proxy forwarding.
func copyProxyRequestHeaders(dst http.Header, src http.Header) {
	for name, values := range src {
		lower := strings.ToLower(name)
		if lower == "host" || lower == "connection" || lower == "transfer-encoding" {
			continue
		}
		for _, value := range values {
			dst.Add(name, value)
		}
	}
}

// Copies response headers while excluding hop-by-hop values.
func copyProxyResponseHeaders(dst http.Header, src http.Header) {
	for name, values := range src {
		lower := strings.ToLower(name)
		if lower == "connection" || lower == "transfer-encoding" {
			continue
		}
		for _, value := range values {
			dst.Add(name, value)
		}
	}
}

// Joins URL path fragments so proxy path rewrites avoid accidental double slashes.
func joinURLPath(basePath string, suffixPath string) string {
	base := strings.TrimSuffix(basePath, "/")
	suffix := "/" + strings.TrimPrefix(suffixPath, "/")
	if base == "" {
		return suffix
	}
	return base + suffix
}
