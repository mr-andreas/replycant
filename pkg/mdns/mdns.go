package mdns

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

const (
	mdnsIPv4Addr          = "224.0.0.251:5353"
	defaultQueryTimeout   = 2 * time.Second
	firstReplyGracePeriod = 150 * time.Millisecond
	minCacheTTL           = 5 * time.Second
	maxCacheTTL           = 2 * time.Minute
)

// answer keeps parsed address records with TTL so lookups can reuse responses briefly.
type answer struct {
	Addr netip.Addr
	TTL  time.Duration
}

// cacheEntry stores resolved addresses until the computed expiration.
type cacheEntry struct {
	Addrs     []netip.Addr
	ExpiresAt time.Time
}

// resolver performs mDNS lookups with a small TTL cache to prevent pre-push query storms.
type resolver struct {
	mu    sync.Mutex
	cache map[string]cacheEntry
	now   func() time.Time
	query func(context.Context, string) ([]answer, error)
}

var defaultResolver = &resolver{
	cache: map[string]cacheEntry{},
	now:   time.Now,
	query: lookupHostViaMDNS,
}

// Lookup resolves host using mDNS and reuses cached answers while TTL remains valid.
func Lookup(ctx context.Context, host string) ([]netip.Addr, error) {
	return defaultResolver.Lookup(ctx, host)
}

// Lookup resolves host with cached TTL-aware answers.
func (r *resolver) Lookup(ctx context.Context, host string) ([]netip.Addr, error) {
	normalized := normalizeHost(host)
	if normalized == "" {
		return nil, fmt.Errorf("host is required")
	}

	now := r.now()
	r.mu.Lock()
	cached, ok := r.cache[normalized]
	if ok && now.Before(cached.ExpiresAt) && len(cached.Addrs) > 0 {
		addrs := append([]netip.Addr(nil), cached.Addrs...)
		r.mu.Unlock()
		return addrs, nil
	}
	r.mu.Unlock()

	answers, err := r.query(ctx, normalized)
	if err != nil {
		return nil, err
	}
	if len(answers) == 0 {
		return nil, fmt.Errorf("mDNS response for %q did not include A or AAAA records", normalized)
	}

	addrs := make([]netip.Addr, 0, len(answers))
	expiresAt := now.Add(maxCacheTTL)
	for _, reply := range answers {
		addrs = append(addrs, reply.Addr)
		ttl := clampTTL(reply.TTL)
		entryExpiry := now.Add(ttl)
		if entryExpiry.Before(expiresAt) {
			expiresAt = entryExpiry
		}
	}

	r.mu.Lock()
	r.cache[normalized] = cacheEntry{
		Addrs:     append([]netip.Addr(nil), addrs...),
		ExpiresAt: expiresAt,
	}
	r.mu.Unlock()
	return addrs, nil
}

// buildQuery creates a single mDNS packet that asks for A and AAAA records.
func buildQuery(host string, id uint16) ([]byte, error) {
	name, err := dnsmessage.NewName(ensureFQDN(host))
	if err != nil {
		return nil, fmt.Errorf("invalid mDNS host %q: %w", host, err)
	}
	quClass := dnsmessage.Class(uint16(dnsmessage.ClassINET) | 0x8000)
	msg := dnsmessage.Message{
		Header: dnsmessage.Header{
			ID:                 id,
			RecursionDesired:   false,
			RecursionAvailable: false,
			Response:           false,
		},
		Questions: []dnsmessage.Question{
			{Name: name, Type: dnsmessage.TypeA, Class: quClass},
			{Name: name, Type: dnsmessage.TypeAAAA, Class: quClass},
		},
	}
	raw, err := msg.Pack()
	if err != nil {
		return nil, fmt.Errorf("failed to pack mDNS query: %w", err)
	}
	return raw, nil
}

// parseAnswers extracts IP answers for host from one DNS payload.
func parseAnswers(payload []byte, host string) ([]answer, error) {
	target := strings.ToLower(ensureFQDN(host))
	msg := dnsmessage.Message{}
	if err := msg.Unpack(payload); err != nil {
		return nil, fmt.Errorf("failed to unpack mDNS response: %w", err)
	}
	if !msg.Header.Response {
		return nil, nil
	}
	results := make([]answer, 0, len(msg.Answers))
	for _, resource := range msg.Answers {
		if strings.ToLower(resource.Header.Name.String()) != target {
			continue
		}
		ttl := time.Duration(resource.Header.TTL) * time.Second
		switch body := resource.Body.(type) {
		case *dnsmessage.AResource:
			addr := netip.AddrFrom4(body.A)
			results = append(results, answer{Addr: addr, TTL: ttl})
		case *dnsmessage.AAAAResource:
			addr := netip.AddrFrom16(body.AAAA)
			results = append(results, answer{Addr: addr, TTL: ttl})
		}
	}
	return results, nil
}

// sendQuery multicasts a packet from each usable interface and gathers direct replies.
func sendQuery(ctx context.Context, dst string, query []byte) ([][]byte, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("failed to list interfaces: %w", err)
	}
	type queryResult struct {
		payloads [][]byte
		err      error
	}
	results := make(chan queryResult, len(interfaces))
	workers := 0
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		if iface.Flags&net.FlagMulticast == 0 && iface.Flags&net.FlagLoopback == 0 {
			continue
		}
		addrs, addrErr := iface.Addrs()
		if addrErr != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet.IP == nil {
				continue
			}
			ipv4 := ipNet.IP.To4()
			if ipv4 == nil {
				continue
			}
			workers++
			go func(localIP net.IP) {
				payloads, runErr := sendQueryFromIP(ctx, dst, localIP, query)
				results <- queryResult{payloads: payloads, err: runErr}
			}(append(net.IP(nil), ipv4...))
		}
	}
	if workers == 0 {
		return nil, fmt.Errorf("no multicast-capable IPv4 interfaces available")
	}

	collected := make([][]byte, 0, workers)
	var joinedErr error
	for i := 0; i < workers; i++ {
		result := <-results
		if result.err != nil {
			joinedErr = errors.Join(joinedErr, result.err)
			continue
		}
		collected = append(collected, result.payloads...)
	}
	if len(collected) > 0 {
		return collected, nil
	}
	if joinedErr != nil {
		return nil, joinedErr
	}
	return nil, fmt.Errorf("mDNS query received no responses")
}

// lookupHostViaMDNS queries mDNS and combines matching A/AAAA answers from all responses.
func lookupHostViaMDNS(ctx context.Context, host string) ([]answer, error) {
	query, err := buildQuery(host, uint16(time.Now().UnixNano()))
	if err != nil {
		return nil, err
	}
	payloads, err := sendQuery(ctx, mdnsIPv4Addr, query)
	if err != nil {
		return nil, err
	}
	allAnswers := make([]answer, 0, len(payloads))
	for _, payload := range payloads {
		answers, parseErr := parseAnswers(payload, host)
		if parseErr != nil {
			continue
		}
		allAnswers = append(allAnswers, answers...)
	}
	if len(allAnswers) == 0 {
		return nil, fmt.Errorf("mDNS response for %q did not include usable A or AAAA records", host)
	}
	return dedupeAnswers(allAnswers), nil
}

// sendQueryFromIP transmits one mDNS packet and captures replies until timeout/grace deadline.
func sendQueryFromIP(ctx context.Context, dst string, localIP net.IP, query []byte) ([][]byte, error) {
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: localIP, Port: 0})
	if err != nil {
		return nil, fmt.Errorf("listen on %s failed: %w", localIP.String(), err)
	}
	defer listener.Close()

	remote, err := net.ResolveUDPAddr("udp4", dst)
	if err != nil {
		return nil, fmt.Errorf("resolve mDNS destination %q failed: %w", dst, err)
	}
	if _, err := listener.WriteToUDP(query, remote); err != nil {
		return nil, fmt.Errorf("send mDNS query from %s failed: %w", localIP.String(), err)
	}

	deadline := deadlineFromContext(ctx, defaultQueryTimeout)
	firstReplyAt := time.Time{}
	buf := make([]byte, 1500)
	payloads := [][]byte{}

	for {
		if err := listener.SetReadDeadline(deadline); err != nil {
			return nil, fmt.Errorf("set mDNS read deadline failed: %w", err)
		}
		n, _, err := listener.ReadFromUDP(buf)
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				break
			}
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, fmt.Errorf("read mDNS response failed: %w", err)
		}
		payloads = append(payloads, append([]byte(nil), buf[:n]...))
		if firstReplyAt.IsZero() {
			firstReplyAt = time.Now()
			graceDeadline := firstReplyAt.Add(firstReplyGracePeriod)
			if graceDeadline.Before(deadline) {
				deadline = graceDeadline
			}
		}
	}
	if len(payloads) == 0 {
		return nil, fmt.Errorf("no mDNS response from %s", localIP.String())
	}
	return payloads, nil
}

// dedupeAnswers keeps first-seen answers while removing duplicate IPs from multiple responders.
func dedupeAnswers(answers []answer) []answer {
	seen := map[netip.Addr]struct{}{}
	deduped := make([]answer, 0, len(answers))
	for _, reply := range answers {
		if _, ok := seen[reply.Addr]; ok {
			continue
		}
		seen[reply.Addr] = struct{}{}
		deduped = append(deduped, reply)
	}
	return deduped
}

// deadlineFromContext keeps query duration bounded while respecting caller cancellation/deadlines.
func deadlineFromContext(ctx context.Context, fallback time.Duration) time.Time {
	deadline := time.Now().Add(fallback)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		return ctxDeadline
	}
	return deadline
}

// clampTTL keeps cache entries short enough for changing LAN addresses while avoiding re-query floods.
func clampTTL(ttl time.Duration) time.Duration {
	if ttl <= 0 {
		return minCacheTTL
	}
	if ttl < minCacheTTL {
		return minCacheTTL
	}
	if ttl > maxCacheTTL {
		return maxCacheTTL
	}
	return ttl
}

// ensureFQDN normalizes names so wire format and comparison always use a trailing dot.
func ensureFQDN(host string) string {
	trimmed := normalizeHost(host)
	if trimmed == "" {
		return "."
	}
	return trimmed + "."
}

// normalizeHost canonicalizes hostnames for cache keys and string comparisons.
func normalizeHost(host string) string {
	trimmed := strings.TrimSpace(strings.TrimSuffix(host, "."))
	return strings.ToLower(trimmed)
}
