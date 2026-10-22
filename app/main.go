// quote-api: a tiny HTTP service used to exercise the platform
// (probes, metrics, HPA, spot/on-demand placement, load testing).
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"log/slog"
	"math/rand/v2" // nosemgrep: go.lang.security.audit.crypto.math_random.math-random-used -- picks a quote, not security-sensitive
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type quote struct {
	Text   string `json:"quote"`
	Author string `json:"author"`
}

var quotes = []quote{
	{"The best way to get started is to quit talking and begin doing.", "Walt Disney"},
	{"It always seems impossible until it's done.", "Nelson Mandela"},
	{"Well done is better than well said.", "Benjamin Franklin"},
	{"Simplicity is prerequisite for reliability.", "Edsger W. Dijkstra"},
	{"Hope is not a strategy.", "Google SRE book"},
	{"Done is better than perfect.", "Sheryl Sandberg"},
}

var (
	requestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "quote_api_requests_total",
		Help: "HTTP requests handled, by route and status code.",
	}, []string{"route", "code"})
	requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "quote_api_request_duration_seconds",
		Help:    "HTTP request latency, by route.",
		Buckets: []float64{0.05, 0.1, 0.125, 0.15, 0.2, 0.3, 0.5, 1, 2, 5},
	}, []string{"route"})
)

// statusRecorder captures the status code so it can be used as a metric label.
type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) { r.code = code; r.ResponseWriter.WriteHeader(code) }

// instrument wraps a handler with request counting and latency metrics.
// The route label is fixed per handler to keep label cardinality bounded.
func instrument(route string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h(rec, r)
		requestsTotal.WithLabelValues(route, strconv.Itoa(rec.code)).Inc()
		requestDuration.WithLabelValues(route).Observe(time.Since(start).Seconds())
	}
}

// burnCPU spins on SHA-256 for roughly d of wall time to simulate real work.
func burnCPU(d time.Duration) {
	sum := sha256.Sum256([]byte("quote"))
	for deadline := time.Now().Add(d); time.Now().Before(deadline); {
		for i := 0; i < 1000; i++ {
			sum = sha256.Sum256(sum[:])
		}
	}
}

func newHandler(ready *atomic.Bool, work time.Duration) http.Handler {
	host, _ := os.Hostname()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", instrument("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok\n"))
	}))
	mux.HandleFunc("GET /readyz", instrument("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !ready.Load() {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("ready\n"))
	}))
	mux.HandleFunc("GET /api/quote", instrument("/api/quote", func(w http.ResponseWriter, _ *http.Request) {
		burnCPU(work)
		q := quotes[rand.IntN(len(quotes))]
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"quote": q.Text, "author": q.Author, "served_by": host})
	}))
	mux.Handle("GET /metrics", promhttp.Handler())
	return mux
}

func envDuration(key string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	work := envDuration("WORK_DURATION", 100*time.Millisecond)
	drain := envDuration("SHUTDOWN_DRAIN", 5*time.Second)

	var ready atomic.Bool
	srv := &http.Server{Addr: ":" + port, Handler: newHandler(&ready, work), ReadHeaderTimeout: 5 * time.Second}

	go func() {
		if err := srv.ListenAndServe(); err != http.ErrServerClosed {
			slog.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()
	ready.Store(true)
	slog.Info("listening", "port", port, "work", work)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	<-ctx.Done()

	// Fail readiness first and keep serving for a moment, so the endpoint is
	// removed from the Service/Ingress before we stop accepting connections.
	slog.Info("shutting down", "drain", drain)
	ready.Store(false)
	time.Sleep(drain)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown", "err", err)
	}
}
