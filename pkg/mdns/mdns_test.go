package mdns

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestBuildQueryIncludesAAndAAAA verifies we request both IP families in one mDNS lookup.
func TestBuildQueryIncludesAAndAAAA(t *testing.T) {
	raw, err := buildQuery("replycant.local", 42)
	require.NoError(t, err)

	var parser dnsmessage.Parser
	header, err := parser.Start(raw)
	require.NoError(t, err)
	assert.False(t, header.Response)
	assert.Equal(t, dnsmessage.OpCode(0), header.OpCode)

	q1, err := parser.Question()
	require.NoError(t, err)
	q2, err := parser.Question()
	require.NoError(t, err)
	_, err = parser.Question()
	require.Error(t, err)

	assert.Equal(t, "replycant.local.", q1.Name.String())
	assert.Equal(t, dnsmessage.TypeA, q1.Type)
	assert.NotZero(t, uint16(q1.Class)&0x8000)
	assert.Equal(t, "replycant.local.", q2.Name.String())
	assert.Equal(t, dnsmessage.TypeAAAA, q2.Type)
	assert.NotZero(t, uint16(q2.Class)&0x8000)
}

// TestParseAnswersReturnsMatchingRecords ensures responders for the requested host map into parsed IPs.
func TestParseAnswersReturnsMatchingRecords(t *testing.T) {
	response := buildMDNSResponse(t, "Replycant.Local", []dnsmessage.Resource{
		{
			Header: dnsmessage.ResourceHeader{
				Name:  mustName(t, "replycant.local."),
				Type:  dnsmessage.TypeA,
				Class: dnsmessage.ClassINET,
				TTL:   120,
			},
			Body: &dnsmessage.AResource{A: [4]byte{192, 168, 0, 25}},
		},
		{
			Header: dnsmessage.ResourceHeader{
				Name:  mustName(t, "replycant.local."),
				Type:  dnsmessage.TypeAAAA,
				Class: dnsmessage.ClassINET,
				TTL:   120,
			},
			Body: &dnsmessage.AAAAResource{AAAA: [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}},
		},
		{
			Header: dnsmessage.ResourceHeader{
				Name:  mustName(t, "other.local."),
				Type:  dnsmessage.TypeA,
				Class: dnsmessage.ClassINET,
				TTL:   120,
			},
			Body: &dnsmessage.AResource{A: [4]byte{10, 0, 0, 4}},
		},
	})

	answers, err := parseAnswers(response, "replycant.local")
	require.NoError(t, err)
	require.Len(t, answers, 2)

	assert.Equal(t, netip.MustParseAddr("192.168.0.25"), answers[0].Addr)
	assert.Equal(t, netip.MustParseAddr("2001:db8::1"), answers[1].Addr)
	assert.Equal(t, 120*time.Second, answers[0].TTL)
	assert.Equal(t, 120*time.Second, answers[1].TTL)
}

// TestLookupCachesByTTL confirms repeated requests avoid multicast churn within cached TTL.
func TestLookupCachesByTTL(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	calls := 0
	r := &resolver{
		now: func() time.Time {
			return now
		},
		cache: map[string]cacheEntry{},
		query: func(context.Context, string) ([]answer, error) {
			calls++
			return []answer{
				{Addr: netip.MustParseAddr("192.168.0.77"), TTL: 10 * time.Second},
			}, nil
		},
	}

	addrs, err := r.Lookup(context.Background(), "replycant.local")
	require.NoError(t, err)
	require.Equal(t, []netip.Addr{netip.MustParseAddr("192.168.0.77")}, addrs)

	now = now.Add(9 * time.Second)
	addrs, err = r.Lookup(context.Background(), "replycant.local")
	require.NoError(t, err)
	require.Equal(t, []netip.Addr{netip.MustParseAddr("192.168.0.77")}, addrs)
	assert.Equal(t, 1, calls)

	now = now.Add(2 * time.Second)
	addrs, err = r.Lookup(context.Background(), "replycant.local")
	require.NoError(t, err)
	require.Equal(t, []netip.Addr{netip.MustParseAddr("192.168.0.77")}, addrs)
	assert.Equal(t, 2, calls)
}

// TestSendQueryReceivesLoopbackResponse checks the UDP query path can collect response datagrams.
func TestSendQueryReceivesLoopbackResponse(t *testing.T) {
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	require.NoError(t, err)
	defer listener.Close()

	response := buildMDNSResponse(t, "replycant.local", []dnsmessage.Resource{
		{
			Header: dnsmessage.ResourceHeader{
				Name:  mustName(t, "replycant.local."),
				Type:  dnsmessage.TypeA,
				Class: dnsmessage.ClassINET,
				TTL:   30,
			},
			Body: &dnsmessage.AResource{A: [4]byte{127, 0, 0, 44}},
		},
	})

	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 1500)
		_ = listener.SetReadDeadline(time.Now().Add(3 * time.Second))
		n, addr, readErr := listener.ReadFromUDP(buf)
		if readErr != nil {
			return
		}
		_, _ = listener.WriteToUDP(response, addr)
		_ = n
	}()

	query, err := buildQuery("replycant.local", 91)
	require.NoError(t, err)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	payloads, err := sendQuery(ctx, listener.LocalAddr().String(), query)
	require.NoError(t, err)
	require.NotEmpty(t, payloads)

	found := false
	for _, payload := range payloads {
		answers, parseErr := parseAnswers(payload, "replycant.local")
		require.NoError(t, parseErr)
		for _, a := range answers {
			if a.Addr == netip.MustParseAddr("127.0.0.44") {
				found = true
			}
		}
	}
	assert.True(t, found)
	<-done
}

func mustName(t *testing.T, name string) dnsmessage.Name {
	t.Helper()
	parsed, err := dnsmessage.NewName(name)
	require.NoError(t, err)
	return parsed
}

func buildMDNSResponse(t *testing.T, host string, answers []dnsmessage.Resource) []byte {
	t.Helper()
	hostName := mustName(t, ensureFQDN(host))

	response := dnsmessage.Message{
		Header: dnsmessage.Header{
			ID:       1,
			Response: true,
		},
		Questions: []dnsmessage.Question{
			{Name: hostName, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET},
		},
		Answers: answers,
	}
	raw, err := response.Pack()
	require.NoError(t, err)
	return raw
}
