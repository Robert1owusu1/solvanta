package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// TestOpenAPISpecServed checks the embedded spec is valid JSON, is served at
// /openapi.json without a token, and advertises the paths the client depends
// on. A broken or empty embed would fail here rather than at a reader's browser.
func TestOpenAPISpecServed(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})

	rec := do(r, "GET", "/openapi.json", "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /openapi.json: %d %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Errorf("content-type = %q, want application/json", ct)
	}

	var spec struct {
		OpenAPI string         `json:"openapi"`
		Info    map[string]any `json:"info"`
		Paths   map[string]any `json:"paths"`
		Comp    map[string]any `json:"components"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &spec); err != nil {
		t.Fatalf("spec is not valid JSON: %v", err)
	}
	if !strings.HasPrefix(spec.OpenAPI, "3.") {
		t.Errorf("openapi version = %q, want 3.x", spec.OpenAPI)
	}
	for _, want := range []string{"/auth/login", "/api/students", "/api/assessments/{id}/scores/bulk", "/api/payments", "/health"} {
		if _, ok := spec.Paths[want]; !ok {
			t.Errorf("spec is missing path %q", want)
		}
	}
}

// TestDocsPageServed checks the Redoc viewer renders and points at the spec.
func TestDocsPageServed(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})

	rec := do(r, "GET", "/docs", "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /docs: %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "<redoc") || !strings.Contains(body, "/openapi.json") {
		t.Errorf("docs page does not embed Redoc pointed at the spec")
	}
}
