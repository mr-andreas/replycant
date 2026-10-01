// Command discovery is the pairing-record store the integration container
// uses in place of the hosted discovery API.
//
// gitd publishes a sealed record with PUT, and the device being paired reads
// it once with GET. Anything else is a 404, which is what the CLI treats as
// "not approved yet". Records are keyed by the slot subdomain so two clones
// in one container cannot observe each other's secrets.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:18082", "Listen address")
	flag.Parse()

	server := &http.Server{Addr: *addr, Handler: newStore()}
	log.Printf("discovery listening on %s", *addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "discovery: %v\n", err)
		os.Exit(1)
	}
}

// store keeps one opaque record per slot. A GET consumes the record so a
// retried poll cannot replay a credential that was already handed out.
type store struct {
	mu      sync.Mutex
	records map[string][]byte
}

func newStore() *store {
	return &store{records: map[string][]byte{}}
}

func (s *store) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	slot := slotFromHost(r.Host)
	if slot == "" || slot == "discovery" {
		http.NotFound(w, r)
		return
	}
	switch r.Method {
	case http.MethodPut:
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil || len(body) == 0 {
			http.Error(w, "record body is required", http.StatusBadRequest)
			return
		}
		s.mu.Lock()
		s.records[slot] = append([]byte(nil), body...)
		s.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	case http.MethodGet:
		s.mu.Lock()
		body, ok := s.records[slot]
		if ok {
			delete(s.records, slot)
		}
		s.mu.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(body)
	default:
		http.NotFound(w, r)
	}
}

// slotFromHost is the first DNS label. The publisher and the CLI both
// address a record as https://<slot>.<discovery-host>/, never as a path.
func slotFromHost(hostport string) string {
	host := hostport
	if split, _, err := net.SplitHostPort(hostport); err == nil {
		host = split
	}
	label, _, _ := strings.Cut(host, ".")
	return strings.TrimSpace(label)
}
