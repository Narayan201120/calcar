package httpserver

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthzReturnsOK(t *testing.T) {
	rr := httptest.NewRecorder()
	New("127.0.0.1:0").Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
	}
	if ct := rr.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}

	var body struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body %q: %v", rr.Body.String(), err)
	}
	if body.Status != "ok" {
		t.Errorf("status = %q, want \"ok\"", body.Status)
	}
}

func TestReadyzReportsNotConfigured(t *testing.T) {
	rr := httptest.NewRecorder()
	New("127.0.0.1:0").Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusServiceUnavailable)
	}

	var body struct {
		Status string `json:"status"`
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body %q: %v", rr.Body.String(), err)
	}
	if body.Status != "unavailable" {
		t.Errorf("status = %q, want \"unavailable\"", body.Status)
	}
	if body.Reason != "not_configured" {
		t.Errorf("reason = %q, want \"not_configured\"", body.Reason)
	}
}

func TestNonGETIsRejected(t *testing.T) {
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		for _, path := range []string{"/healthz", "/readyz"} {
			rr := httptest.NewRecorder()
			New("127.0.0.1:0").Handler().ServeHTTP(rr, httptest.NewRequest(method, path, nil))
			if rr.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s: status = %d, want %d", method, path, rr.Code, http.StatusMethodNotAllowed)
			}
		}
	}
}

func TestUnknownPathIsNotFound(t *testing.T) {
	for _, path := range []string{"/", "/unknown", "/healthz/extra"} {
		rr := httptest.NewRecorder()
		New("127.0.0.1:0").Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code != http.StatusNotFound {
			t.Errorf("GET %s: status = %d, want %d", path, rr.Code, http.StatusNotFound)
		}
	}
}
