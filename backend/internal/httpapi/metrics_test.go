package httpapi

import (
	"net/http"
	"strings"
	"testing"
)

func TestMetricsEndpointOpenByDefault(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	// Generate a little traffic.
	do(r, "GET", "/health", "", nil)
	do(r, "GET", "/health", "", nil)

	rec := do(r, "GET", "/metrics", "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("metrics: %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "solvanta_http_requests_total") ||
		!strings.Contains(body, "solvanta_http_requests_count") {
		t.Errorf("metrics body missing counters:\n%s", body)
	}
}

func TestMetricsEndpointTokenGated(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{MetricsToken: "scrape-secret"})
	if rec := do(r, "GET", "/metrics", "", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("no token: got %d want 401", rec.Code)
	}
	if rec := do(r, "GET", "/metrics", "", map[string]string{"Authorization": "Bearer scrape-secret"}); rec.Code != http.StatusOK {
		t.Errorf("with token: got %d want 200", rec.Code)
	}
}
