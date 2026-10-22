package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestProbes(t *testing.T) {
	var ready atomic.Bool
	h := newHandler(&ready, 0)

	if rec := get(t, h, "/healthz"); rec.Code != http.StatusOK {
		t.Fatalf("/healthz = %d, want 200", rec.Code)
	}
	if rec := get(t, h, "/readyz"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("/readyz before ready = %d, want 503", rec.Code)
	}
	ready.Store(true)
	if rec := get(t, h, "/readyz"); rec.Code != http.StatusOK {
		t.Fatalf("/readyz after ready = %d, want 200", rec.Code)
	}
}

func TestQuote(t *testing.T) {
	var ready atomic.Bool
	work := 50 * time.Millisecond
	h := newHandler(&ready, work)

	start := time.Now()
	rec := get(t, h, "/api/quote")
	if took := time.Since(start); took < work {
		t.Errorf("request took %v, want at least %v of simulated work", took, work)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("/api/quote = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if body["quote"] == "" || body["author"] == "" {
		t.Errorf("missing fields in %v", body)
	}
}

func TestMetrics(t *testing.T) {
	var ready atomic.Bool
	h := newHandler(&ready, 0)
	get(t, h, "/api/quote")

	rec := get(t, h, "/metrics")
	if rec.Code != http.StatusOK {
		t.Fatalf("/metrics = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `quote_api_requests_total{code="200",route="/api/quote"}`) {
		t.Errorf("custom counter not exported:\n%s", rec.Body.String())
	}
}
