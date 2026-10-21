package httpapi

import (
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"

	sec "solvanta/backend/internal/security"
)

// defaultBodyLimit caps JSON request bodies at 1 MiB.
const defaultBodyLimit = 1 << 20

// Config holds server security settings (env-driven).
type Config struct {
	// Secret signs bearer tokens. When empty (dev) a random per-process key is
	// generated; Production requires it to be set explicitly.
	Secret string
	// AllowedOrigins enables CORS for the listed web origins (comma-separated
	// in the ALLOWED_ORIGINS env var). Empty means no CORS headers.
	AllowedOrigins []string
	// Production refuses to boot without an explicit Secret.
	Production bool
}

// sharedPasswordHashes precomputes bcrypt hashes once per process so repeated
// store seeding stays fast and deterministic in cost.
var sharedPasswordHashes = sync.OnceValue(func() map[string]string {
	out := make(map[string]string, 8)
	for _, pw := range []string{
		"super123", "admin123", "head123", "teacher123", "parent123", "student123",
	} {
		h, err := sec.HashPassword(pw)
		if err != nil {
			panic("bcrypt: " + err.Error())
		}
		out[pw] = h
	}
	return out
})

// dummyPasswordHash defeats timing-based user enumeration on login.
var dummyPasswordHash = sync.OnceValue(func() []byte {
	h, err := bcrypt.GenerateFromPassword([]byte("solvanta-dummy-sentinel"), bcrypt.DefaultCost)
	if err != nil {
		panic(err)
	}
	return h
})

// hashPassword returns the bcrypt hash for pw. Seed passwords reuse the
// precomputed hashes (stable across store re-seeding); anything else is hashed
// fresh at DefaultCost.
func hashPassword(pw string) string {
	if h, ok := sharedPasswordHashes()[pw]; ok {
		return h
	}
	h, err := sec.HashPassword(pw)
	if err != nil {
		panic(err)
	}
	return h
}

func tcExpiry(tc tokenClaims) time.Time { return time.Unix(tc.Exp, 0) }

// VerifyPassword compares a candidate password with a stored hash in
// constant time (bcrypt). For unknown accounts callers compare against
// dummyPasswordHash to avoid user-enumeration timing.
func verifyPassword(stored, candidate string) bool {
	return sec.VerifyPassword(stored, candidate)
}

// burnCandidate spends a bcrypt comparison on non-existent accounts so login
// latency does not reveal whether an email is registered.
func burnCandidate(candidate string) {
	_ = bcrypt.CompareHashAndPassword(dummyPasswordHash(), []byte(candidate))
}

func validEmail(e string) bool {
	e = strings.TrimSpace(e)
	if len(e) < 3 || len(e) > 254 || strings.ContainsAny(e, " \t\r\n") {
		return false
	}
	at := strings.LastIndexByte(e, '@')
	if at <= 0 || at == len(e)-1 {
		return false
	}
	local, domain := e[:at], e[at+1:]
	if strings.Contains(local, "@") || !strings.Contains(domain, ".") {
		return false
	}
	return true
}

// checkPasswordPolicy applies the platform policy (security package) plus the
// bcrypt input cap, returning a user-facing message or "" when acceptable.
func checkPasswordPolicy(pw string) string {
	if utf8.RuneCountInString(pw) > 72 {
		return "password must be 72 characters or fewer"
	}
	if err := sec.ValidatePasswordPolicy(pw); err != nil {
		return err.Error()
	}
	return ""
}

func validRole(role string) bool {
	switch role {
	case "superAdmin", "schoolAdmin", "headteacher", "teacher", "parent", "student", "staff", "educationAuthority":
		return true
	}
	return false
}

// securityHeaders sets baseline hardening headers on every response.
func (s *Server) securityHeaders() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("X-Content-Type-Options", "nosniff")
		c.Header("X-Frame-Options", "DENY")
		c.Header("Referrer-Policy", "no-referrer")
		c.Header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		c.Header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		if c.Request.Header.Get("X-Forwarded-Proto") == "https" || s.cfg.Production {
			c.Header("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		switch {
		case strings.HasPrefix(c.Request.URL.Path, "/auth/"),
			strings.HasPrefix(c.Request.URL.Path, "/api/notifications"):
			c.Header("Cache-Control", "no-store")
		}
		c.Next()
	}
}

// cors echoes the request Origin only when it is allow-listed.
func (s *Server) cors() gin.HandlerFunc {
	allow := map[string]bool{}
	for _, o := range s.cfg.AllowedOrigins {
		allow[strings.TrimRight(o, "/")] = true
	}
	return func(c *gin.Context) {
		origin := c.Request.Header.Get("Origin")
		if origin == "" || !allow[strings.TrimRight(origin, "/")] {
			c.Next()
			return
		}
		c.Header("Access-Control-Allow-Origin", origin)
		c.Header("Vary", "Origin")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type")
		c.Header("Access-Control-Max-Age", "600")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

// limitRequestBody caps the request body and makes oversized bodies yield 413.
func limitRequestBody() gin.HandlerFunc {
	return func(c *gin.Context) {
		limit := int64(defaultBodyLimit)
		if c.Request.Method == http.MethodPut && strings.HasSuffix(c.Request.URL.Path, "/image") {
			limit = maxScanImage
		}
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, limit)
		c.Next()
	}
}

// isBodyTooLarge reports whether err came from the size cap (→ 413).
func isBodyTooLarge(err error) bool {
	var maxErr *http.MaxBytesError
	return errors.As(err, &maxErr)
}

// rateLimiter is a fixed-window in-memory limiter.
type rateLimiter struct {
	mu     sync.Mutex
	hits   map[string][]time.Time
	limit  int
	window time.Duration
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	return &rateLimiter{hits: map[string][]time.Time{}, limit: limit, window: window}
}

func (r *rateLimiter) allow(key string) bool {
	now := time.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	cutoff := now.Add(-r.window)
	recent := r.hits[key][:0]
	for _, t := range r.hits[key] {
		if t.After(cutoff) {
			recent = append(recent, t)
		}
	}
	if len(recent) >= r.limit {
		r.hits[key] = recent
		return false
	}
	r.hits[key] = append(recent, now)
	if len(r.hits) > 8192 {
		for k := range r.hits {
			if r.hits[k][0].Before(cutoff) {
				delete(r.hits, k)
			}
		}
	}
	return true
}

// loginRateLimit throttles brute-force attempts per client IP (10/min).
func (s *Server) loginRateLimit() gin.HandlerFunc {
	rl := newRateLimiter(10, time.Minute)
	return func(c *gin.Context) {
		if !rl.allow(c.ClientIP()) {
			fail(c, http.StatusTooManyRequests, "Too many login attempts. Try again in a minute.")
			c.Abort()
			return
		}
		c.Next()
	}
}

// apiRateLimit throttles authenticated requests per user (300/min).
func (s *Server) apiRateLimit() gin.HandlerFunc {
	rl := newRateLimiter(300, time.Minute)
	return func(c *gin.Context) {
		u := currentUser(c)
		if !rl.allow(u.ID) {
			fail(c, http.StatusTooManyRequests, "Rate limit exceeded.")
			c.Abort()
			return
		}
		c.Next()
	}
}

func randomHex(n int) string {
	s, err := sec.RandomHex(n)
	if err != nil {
		panic(err)
	}
	return s
}

func randomSecret() string {
	s, err := sec.RandomToken(32)
	if err != nil {
		panic(err)
	}
	return s
}

// tokenClaims is the signed payload: sub.exp.iat.jti (compact, not a JWT
// dependency; HMAC-SHA256 over the compact JSON is transport-agnostic).
type tokenClaims struct {
	Sub string `json:"sub"`
	Exp int64  `json:"exp"`
	Iat int64  `json:"iat"`
	Jti string `json:"jti"`
}
