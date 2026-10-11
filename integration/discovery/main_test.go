package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPutThenGetConsumesTheRecord(t *testing.T) {
	handler := newStore()
	put := httptest.NewRequest(http.MethodPut, "/", strings.NewReader("sealed"))
	put.Host = "abc.discovery.test:18082"
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, put)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("PUT status = %d", rec.Code)
	}

	got := getSlot(t, handler, "abc.discovery.test")
	if got != "sealed" {
		t.Fatalf("GET body = %q", got)
	}
	again := httptest.NewRequest(http.MethodGet, "/", nil)
	again.Host = "abc.discovery.test"
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, again)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("second GET status = %d, want 404", rec.Code)
	}
}

func TestSlotsDoNotShareRecords(t *testing.T) {
	handler := newStore()
	put := httptest.NewRequest(http.MethodPut, "/", strings.NewReader("one"))
	put.Host = "aaa.discovery.test"
	handler.ServeHTTP(httptest.NewRecorder(), put)

	other := httptest.NewRequest(http.MethodGet, "/", nil)
	other.Host = "bbb.discovery.test"
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, other)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("other slot status = %d", rec.Code)
	}
}

func TestOtherMethodsAreNotFound(t *testing.T) {
	handler := newStore()
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.Host = "abc.discovery.test"
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("POST status = %d", rec.Code)
	}
}

// The desktop app polls from its renderer, which is a cross-origin fetch.
// Without the header the browser hides even the 404, and the poll can never
// tell "not approved yet" from a network failure.
func TestReadsAreOpenToOtherOrigins(t *testing.T) {
	handler := newStore()
	for _, published := range []bool{false, true} {
		if published {
			put := httptest.NewRequest(http.MethodPut, "/", strings.NewReader("sealed"))
			put.Host = "abc.discovery.test"
			handler.ServeHTTP(httptest.NewRecorder(), put)
		}
		get := httptest.NewRequest(http.MethodGet, "/", nil)
		get.Host = "abc.discovery.test"
		get.Header.Set("Origin", "http://127.0.0.1:5173")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, get)
		if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
			t.Errorf("published=%v: Access-Control-Allow-Origin = %q, want *", published, got)
		}
	}
}

func getSlot(t *testing.T, handler http.Handler, host string) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Host = host
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status = %d", rec.Code)
	}
	body, err := io.ReadAll(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}
