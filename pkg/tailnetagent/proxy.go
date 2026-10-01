package tailnetagent

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// DialFunc opens a TCP connection the way the tailnet node would.
//
// Tests supply a dialer that never touches WireGuard, so the proxy's
// authentication and splicing can be checked without a control plane.
type DialFunc func(ctx context.Context, network, addr string) (net.Conn, error)

// Proxy is the loopback CONNECT endpoint git and git-lfs dial through.
//
// CONNECT rather than SOCKS5 because both git and git-lfs already speak it.
// mTLS still terminates at gitd: this proxy only decides which TCP connection
// the bytes travel over.
type Proxy struct {
	Dial     DialFunc
	Username string
	Password string

	mu           sync.Mutex
	conns        int
	lastActivity time.Time
}

// touch marks the proxy in use so an idle timeout starts from real activity
// rather than from process start.
func (p *Proxy) touch() {
	p.mu.Lock()
	p.lastActivity = time.Now()
	p.mu.Unlock()
}

func (p *Proxy) begin() {
	p.mu.Lock()
	p.conns++
	p.lastActivity = time.Now()
	p.mu.Unlock()
}

func (p *Proxy) end() {
	p.mu.Lock()
	p.conns--
	p.lastActivity = time.Now()
	p.mu.Unlock()
}

// idle reports how long the proxy has had nothing to forward.
//
// A live connection keeps the agent up, because a push holds the transport
// and the pre-push hook open together and neither can restart the node.
func (p *Proxy) idle(now time.Time) time.Duration {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.conns > 0 || p.lastActivity.IsZero() {
		return 0
	}
	return now.Sub(p.lastActivity)
}

func (p *Proxy) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !p.authorized(r) {
			w.Header().Set("Proxy-Authenticate", `Basic realm="replycant-tailnet"`)
			http.Error(w, "proxy authentication required", http.StatusProxyAuthRequired)
			return
		}
		if r.Method != http.MethodConnect {
			p.forwardHTTP(w, r)
			return
		}
		if p.Dial == nil {
			http.Error(w, "tailnet dialer is not configured", http.StatusBadGateway)
			return
		}

		p.begin()
		defer p.end()

		dest, err := p.Dial(r.Context(), "tcp", r.Host)
		if err != nil {
			http.Error(w, "tailnet dial failed", http.StatusBadGateway)
			return
		}
		defer dest.Close()

		hijacker, ok := w.(http.Hijacker)
		if !ok {
			http.Error(w, "proxy cannot take over the connection", http.StatusInternalServerError)
			return
		}
		client, _, err := hijacker.Hijack()
		if err != nil {
			return
		}
		defer client.Close()

		if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
			return
		}
		splice(client, dest)
	})
}

// authorized checks the credential embedded in the proxy URL.
//
// The proxy binds loopback, but other local users can still connect to it,
// and the credential is what keeps them from dialing the tailnet as this repo.
// authorized reads Proxy-Authorization, which is what clients send for a
// CONNECT proxy. Request.BasicAuth only looks at Authorization, and that
// header is reserved for the origin server behind the proxy.
func (p *Proxy) authorized(r *http.Request) bool {
	user, password, ok := proxyBasicAuth(r.Header.Get("Proxy-Authorization"))
	if !ok {
		return false
	}
	userOK := subtle.ConstantTimeCompare([]byte(user), []byte(p.Username)) == 1
	passOK := subtle.ConstantTimeCompare([]byte(password), []byte(p.Password)) == 1
	return userOK && passOK
}

// forwardHTTP carries plain HTTP through the same dialer as CONNECT.
//
// git and git-lfs use CONNECT for https. A forward path is still required
// so an HTTP client pointed at this proxy, including tests, does not bypass
// the tailnet dialer.
func (p *Proxy) forwardHTTP(w http.ResponseWriter, r *http.Request) {
	host := r.URL.Host
	if host == "" {
		host = r.Host
	}
	if host == "" {
		http.Error(w, "proxy request has no host", http.StatusBadRequest)
		return
	}
	if !strings.Contains(host, ":") {
		host += ":80"
	}

	p.begin()
	defer p.end()

	transport := &http.Transport{DialContext: p.Dial}
	defer transport.CloseIdleConnections()
	outbound := r.Clone(r.Context())
	outbound.RequestURI = ""
	response, err := transport.RoundTrip(outbound)
	if err != nil {
		http.Error(w, "tailnet dial failed", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	for key, values := range response.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	_, _ = io.Copy(w, response.Body)
}

func proxyBasicAuth(header string) (string, string, bool) {
	const prefix = "Basic "
	if len(header) < len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return "", "", false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(header[len(prefix):]))
	if err != nil {
		return "", "", false
	}
	user, password, ok := strings.Cut(string(raw), ":")
	if !ok {
		return "", "", false
	}
	return user, password, true
}

// splice copies until either side finishes.
//
// Closing both sides unblocks the opposite copy, so one finished request
// does not leave a goroutine parked on the tailnet connection.
func splice(left, right net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(right, left)
		_ = right.Close()
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(left, right)
		_ = left.Close()
	}()
	wg.Wait()
}
