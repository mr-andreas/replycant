package mdns

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"strings"
)

var (
	realDialer      = &net.Dialer{}
	realDialContext = realDialer.DialContext
	systemLookupIP  = func(ctx context.Context, host string) ([]net.IPAddr, error) {
		return net.DefaultResolver.LookupIPAddr(ctx, host)
	}
	lookupMDNS  = Lookup
	dialContext = realDialContext
)

// DialContext keeps .local connectivity working for static Go builds by falling back to mDNS.
func DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, splitErr := net.SplitHostPort(addr)
	if splitErr != nil {
		return dialContext(ctx, network, addr)
	}
	normalizedHost := strings.TrimSuffix(host, ".")
	if ip := net.ParseIP(normalizedHost); ip != nil {
		return dialContext(ctx, network, addr)
	}
	if !isLocalHostname(normalizedHost) {
		return dialContext(ctx, network, addr)
	}

	systemIPs, systemErr := systemLookupIP(ctx, normalizedHost)
	if systemErr == nil && len(systemIPs) > 0 {
		return dialContext(ctx, network, net.JoinHostPort(systemIPs[0].IP.String(), port))
	}
	if systemErr == nil {
		systemErr = fmt.Errorf("system resolver returned no addresses")
	}

	mdnsIPs, mdnsErr := lookupMDNS(ctx, normalizedHost)
	if mdnsErr != nil {
		return nil, fmt.Errorf(
			"failed to resolve %q via system DNS (%w) and mDNS (%w)",
			normalizedHost,
			systemErr,
			mdnsErr,
		)
	}
	if len(mdnsIPs) == 0 {
		return nil, fmt.Errorf(
			"failed to resolve %q via system DNS (%w) and mDNS (no addresses)",
			normalizedHost,
			systemErr,
		)
	}
	return dialContext(ctx, network, joinAddr(mdnsIPs[0], port))
}

// isLocalHostname scopes fallback to `.local` names so regular DNS paths are unchanged.
func isLocalHostname(host string) bool {
	return strings.HasSuffix(strings.ToLower(strings.TrimSpace(host)), ".local")
}

// joinAddr formats an IP address for net.Dial including brackets for IPv6.
func joinAddr(addr netip.Addr, port string) string {
	return net.JoinHostPort(addr.String(), port)
}
