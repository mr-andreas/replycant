package gitd

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
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
	lfsProxyPathPrefix        = "/lfs"
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

	// Only the LFS batch API embeds absolute upstream URLs in its responses, so
	// href rewriting is opt-in rather than applied to every proxied service.
	rewritesLFSBatchActions bool
}

// Parses a configured upstream URL and normalizes it for authenticated proxying.
// Returns a nil proxy for an empty URL so tests and partial deployments can omit
// services they do not exercise.
func newServiceProxy(pathPrefix string, rawURL string, rewritesLFSBatchActions bool) (*serviceProxy, error) {
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
		pathPrefix:              pathPrefix,
		upstreamBaseURL:         parsed,
		upstreamAuth:            authHeader,
		upstreamPathBase:        basePath,
		httpClient:              &http.Client{Timeout: 5 * time.Minute},
		rewritesLFSBatchActions: rewritesLFSBatchActions,
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

	if proxy.rewritesLFSBatchActions && shouldRewriteBatchResponse(r, upstreamRes) {
		return s.writeRewrittenBatchResponse(proxy, w, r, upstreamRes)
	}
	copyProxyResponseHeaders(w.Header(), upstreamRes.Header, false)
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

// Rewrites LFS batch actions so follow-up upload/download requests stay on the mTLS /lfs route.
func (s *Server) writeRewrittenBatchResponse(proxy *serviceProxy, w http.ResponseWriter, r *http.Request, upstreamRes *http.Response) error {
	body, err := io.ReadAll(upstreamRes.Body)
	if err != nil {
		return fmt.Errorf("read upstream batch response: %w", err)
	}

	rewrittenBody, err := rewriteBatchHrefs(proxy, r, body)
	if err != nil {
		return fmt.Errorf("rewrite batch response: %w", err)
	}

	copyProxyResponseHeaders(w.Header(), upstreamRes.Header, true)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(rewrittenBody)))
	w.WriteHeader(upstreamRes.StatusCode)
	_, err = io.Copy(w, bytes.NewReader(rewrittenBody))
	return err
}

// Applies public gitd host rewriting to LFS batch action href values.
func rewriteBatchHrefs(proxy *serviceProxy, r *http.Request, body []byte) ([]byte, error) {
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		return body, nil
	}

	objects, ok := payload["objects"].([]any)
	if !ok {
		return body, nil
	}

	publicBase := buildPublicBaseURL(r, proxy.pathPrefix)
	for _, objectEntry := range objects {
		objectMap, ok := objectEntry.(map[string]any)
		if !ok {
			continue
		}
		actions, ok := objectMap["actions"].(map[string]any)
		if !ok {
			continue
		}
		for actionName, actionEntry := range actions {
			actionMap, ok := actionEntry.(map[string]any)
			if !ok {
				continue
			}
			href, ok := actionMap["href"].(string)
			if !ok || strings.TrimSpace(href) == "" {
				continue
			}
			rewritten, err := proxy.rewriteActionHref(href, publicBase)
			if err != nil {
				continue
			}
			actionMap["href"] = rewritten
			actions[actionName] = actionMap
		}
		objectMap["actions"] = actions
	}

	rewrittenBody, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return rewrittenBody, nil
}

// Converts upstream LFS action URLs to equivalent URLs under gitd's public prefix.
func (p *serviceProxy) rewriteActionHref(rawHref string, publicBase *url.URL) (string, error) {
	parsedHref, err := url.Parse(rawHref)
	if err != nil {
		return "", err
	}

	relativePath := parsedHref.Path
	if p.upstreamPathBase != "" && strings.HasPrefix(relativePath, p.upstreamPathBase) {
		relativePath = strings.TrimPrefix(relativePath, p.upstreamPathBase)
		if !strings.HasPrefix(relativePath, "/") {
			relativePath = "/" + relativePath
		}
	}

	target := *publicBase
	target.Path = joinURLPath(publicBase.Path, relativePath)
	target.RawQuery = parsedHref.RawQuery
	target.Fragment = ""
	return target.String(), nil
}

// Detects batch API responses that require href rewriting for continued mTLS routing.
func shouldRewriteBatchResponse(req *http.Request, upstreamRes *http.Response) bool {
	if req.Method != http.MethodPost {
		return false
	}
	if !strings.HasSuffix(strings.TrimSuffix(req.URL.Path, "/"), "/objects/batch") {
		return false
	}
	if upstreamRes.StatusCode < 200 || upstreamRes.StatusCode >= 300 {
		return false
	}
	contentType := strings.ToLower(upstreamRes.Header.Get("Content-Type"))
	return strings.Contains(contentType, "application/vnd.git-lfs+json") || strings.Contains(contentType, "application/json")
}

// Builds the externally reachable base URL for a proxied service from the active gitd request host.
func buildPublicBaseURL(r *http.Request, pathPrefix string) *url.URL {
	scheme := "https"
	if r.TLS == nil {
		scheme = "http"
	}
	return &url.URL{
		Scheme: scheme,
		Host:   r.Host,
		Path:   pathPrefix,
	}
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

// Copies response headers while optionally dropping content-length for rewritten payloads.
func copyProxyResponseHeaders(dst http.Header, src http.Header, rewritingBody bool) {
	for name, values := range src {
		lower := strings.ToLower(name)
		if lower == "connection" || lower == "transfer-encoding" {
			continue
		}
		if rewritingBody && lower == "content-length" {
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
