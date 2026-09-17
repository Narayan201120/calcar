// Package httpserver holds the Calcar API's HTTP server and its handlers.
// Pre-database stage: /healthz reports liveness, /readyz always reports
// not-ready until backing services are wired up.
package httpserver

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"time"
)

// DefaultAddr is the loopback address the server binds to when
// CALCAR_ADDR is unset.
const DefaultAddr = "127.0.0.1:8080"

// Server wraps the http.Server with Calcar's routes.
type Server struct {
	http *http.Server
}

// New returns a Server bound to addr.
func New(addr string) *Server {
	return &Server{
		http: &http.Server{
			Addr:              addr,
			Handler:           routes(),
			ReadHeaderTimeout: readHeaderTimeout,
		},
	}
}

// ListenAndServe runs the server. It returns http.ErrServerClosed after a
// successful Shutdown.
func (s *Server) ListenAndServe() error { return s.http.ListenAndServe() }

// Serve accepts connections on ln. It returns http.ErrServerClosed after a
// successful Shutdown.
func (s *Server) Serve(ln net.Listener) error { return s.http.Serve(ln) }

// Shutdown gracefully drains connections within ctx's deadline.
func (s *Server) Shutdown(ctx context.Context) error { return s.http.Shutdown(ctx) }

// Handler exposes the routed handler for tests.
func (s *Server) Handler() http.Handler { return s.http.Handler }

const readHeaderTimeout = 5 * time.Second

func routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /readyz", handleReadyz)
	return mux
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func handleReadyz(w http.ResponseWriter, _ *http.Request) {
	// No database yet: readiness is intentionally unconfigured.
	writeJSON(w, http.StatusServiceUnavailable, map[string]string{
		"status": "unavailable",
		"reason": "not_configured",
	})
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		http.Error(w, "encode response", http.StatusInternalServerError)
	}
}
