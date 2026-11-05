package metrics

import (
	"strings"
	"testing"
	"time"
)

func TestRegistryRendersPrometheus(t *testing.T) {
	r := New()
	r.Observe(200, 5*time.Millisecond)
	r.Observe(200, 7*time.Millisecond)
	r.Observe(404, 1*time.Millisecond)

	out := r.Render()
	for _, want := range []string{
		`solvanta_http_requests_total{status="200"} 2`,
		`solvanta_http_requests_total{status="404"} 1`,
		"solvanta_http_requests_count 3",
		"solvanta_http_request_duration_ms_sum ",
		"solvanta_uptime_seconds ",
		"# TYPE solvanta_http_requests_total counter",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("render missing %q in:\n%s", want, out)
		}
	}
}
