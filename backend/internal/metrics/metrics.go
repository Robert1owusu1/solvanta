// Package metrics is a tiny, dependency-free Prometheus exposition for the API:
// request counts by status, total request duration, and process uptime —
// enough for a dashboard and alerts without pulling in a client library.
package metrics

import (
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Registry collects HTTP request metrics. Safe for concurrent use.
type Registry struct {
	mu          sync.Mutex
	byStatus    map[int]int64
	totalReqs   int64
	totalMillis int64
	started     time.Time
}

// New returns an empty registry stamped with the process start time.
func New() *Registry {
	return &Registry{byStatus: map[int]int64{}, started: time.Now()}
}

// Observe records one finished request.
func (r *Registry) Observe(status int, dur time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.byStatus[status]++
	r.totalReqs++
	r.totalMillis += dur.Milliseconds()
}

// Render returns the metrics in Prometheus text exposition format.
func (r *Registry) Render() string {
	r.mu.Lock()
	defer r.mu.Unlock()

	var b strings.Builder
	b.WriteString("# HELP solvanta_http_requests_total HTTP requests by status code.\n")
	b.WriteString("# TYPE solvanta_http_requests_total counter\n")
	codes := make([]int, 0, len(r.byStatus))
	for code := range r.byStatus {
		codes = append(codes, code)
	}
	sort.Ints(codes)
	for _, code := range codes {
		b.WriteString(`solvanta_http_requests_total{status="`)
		b.WriteString(strconv.Itoa(code))
		b.WriteString(`"} `)
		b.WriteString(strconv.FormatInt(r.byStatus[code], 10))
		b.WriteByte('\n')
	}

	b.WriteString("# HELP solvanta_http_request_duration_ms_sum Total request handling time (ms).\n")
	b.WriteString("# TYPE solvanta_http_request_duration_ms_sum counter\n")
	b.WriteString("solvanta_http_request_duration_ms_sum ")
	b.WriteString(strconv.FormatInt(r.totalMillis, 10))
	b.WriteByte('\n')

	b.WriteString("# HELP solvanta_http_requests_count Total requests observed.\n")
	b.WriteString("# TYPE solvanta_http_requests_count counter\n")
	b.WriteString("solvanta_http_requests_count ")
	b.WriteString(strconv.FormatInt(r.totalReqs, 10))
	b.WriteByte('\n')

	b.WriteString("# HELP solvanta_uptime_seconds Seconds since the process started.\n")
	b.WriteString("# TYPE solvanta_uptime_seconds gauge\n")
	b.WriteString("solvanta_uptime_seconds ")
	b.WriteString(strconv.FormatInt(int64(time.Since(r.started).Seconds()), 10))
	b.WriteByte('\n')

	return b.String()
}
