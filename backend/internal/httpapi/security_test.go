package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/store"
)

// newTestServer builds a fresh seeded store + API server in test mode.
func newTestServer(t *testing.T, cfg Config) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	s, err := NewServer(store.New(), cfg)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return s.Router()
}

// do sends a JSON request and returns the recorder.
func do(r http.Handler, method, path, body string, hdr map[string]string) *httptest.ResponseRecorder {
	var req *http.Request
	if body != "" {
		req = httptest.NewRequest(method, path, strings.NewReader(body))
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	return rec
}

// login returns a bearer token for the demo account, failing the test on error.
func login(t *testing.T, r http.Handler, email, pw string) string {
	t.Helper()
	rec := do(r, "POST", "/auth/login", fmt.Sprintf(`{"email":%q,"password":%q}`, email, pw), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("login %s: got %d %s", email, rec.Code, rec.Body.String())
	}
	var resp struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal login: %v", err)
	}
	if resp.Token == "" {
		t.Fatal("login returned no token")
	}
	return resp.Token
}

func TestLoginAndAuthMe(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "kojo.owusu@school.gh", "student123")
	rec := do(r, "GET", "/auth/me", "", map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /auth/me: %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "password") {
		t.Fatalf("password leaked in /auth/me: %s", rec.Body.String())
	}
}

func TestLoginRejectsBadCredentialsUniformly(t *testing.T) {
	r := newTestServer(t, Config{})
	for i, tc := range []struct{ email, pw string }{
		{"kojo.owusu@school.gh", "wrongpass1"},
		{"nobody@school.gh", "wrongpass1"},
		{"nobody@school.gh", ""},
	} {
		rec := do(r, "POST", "/auth/login", fmt.Sprintf(`{"email":%q,"password":%q}`, tc.email, tc.pw), nil)
		// missing password is 400 (bind-level), the rest are indistinguishable 401s
		want := http.StatusUnauthorized
		if tc.pw == "" {
			want = http.StatusBadRequest
		}
		if rec.Code != want {
			t.Fatalf("case %d: got %d, want %d (%s)", i, rec.Code, want, rec.Body.String())
		}
	}
}

func TestLoginRateLimit(t *testing.T) {
	r := newTestServer(t, Config{})
	for i := 0; i < 10; i++ {
		rec := do(r, "POST", "/auth/login", `{"email":"kojo.owusu@school.gh","password":"nopeNope1"}`, nil)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: got %d, want 401", i, rec.Code)
		}
	}
	rec := do(r, "POST", "/auth/login", `{"email":"kojo.owusu@school.gh","password":"nopeNope1"}`, nil)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("11th attempt: got %d, want 429", rec.Code)
	}
}

func TestTamperedAndExpiredTokens(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "admin@solvanta.app", "admin123")
	sig := strings.LastIndex(tok, ".")
	if sig < 0 || len(tok)-sig-1 < 3 {
		t.Fatalf("unexpected token shape: %q", tok)
	}

	// 1. A full signature character is overwritten, changing the decoded MAC.
	//    Pick a middle character: only the very last character of a base64
	//    string carries partial bits, so editing that one can be a no-op.
	i := sig + 1 + (len(tok)-sig-1)/2
	alt := byte('A')
	if tok[i] == 'A' {
		alt = 'B'
	}
	tampered := tok[:i] + string(alt) + tok[i+1:]
	if tampered == tok {
		t.Fatal("test bug: tampered token equals the original")
	}
	rec := do(r, "GET", "/api/subjects", "", map[string]string{"Authorization": "Bearer " + tampered})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("tampered signature: got %d, want 401", rec.Code)
	}

	// 2. A "twin": different text, identical decoded signature. The signature
	//    ends in a character whose two low bits are pure padding, so flipping
	//    one of them yields a string that decodes to the very same MAC and
	//    would be accepted by a decoder that does not re-encode. Server-issued
	//    signatures are canonical, so that flip is always available.
	const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	j := strings.IndexByte(alpha, tok[len(tok)-1])
	if j < 0 {
		t.Fatalf("unexpected final character in token %q", tok)
	}
	twin := tok[:len(tok)-1] + string(alpha[j^1])
	if twin == tok {
		t.Fatal("test bug: non-canonical twin equals the original token")
	}
	rec = do(r, "GET", "/api/subjects", "", map[string]string{"Authorization": "Bearer " + twin})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("non-canonical twin of a valid token: got %d, want 401", rec.Code)
	}

	// The token itself still works, so the rejections above are not an
	// artifact of a broken login.
	rec = do(r, "GET", "/api/subjects", "", map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusOK {
		t.Fatalf("untampered token: got %d, want 200 (%s)", rec.Code, rec.Body.String())
	}

	rec = do(r, "GET", "/api/subjects", "", nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("missing token: got %d, want 401", rec.Code)
	}

	// An expired token signed by this server must be rejected.
	s, _ := NewServer(store.New(), Config{})
	u, _, ok := s.userByEmail("super@solvanta.app")
	if !ok {
		t.Fatal("super user missing from seed")
	}
	expired := s.sign(u, -time.Minute)
	rec = do(s.Router(), "GET", "/api/subjects", "", map[string]string{"Authorization": "Bearer " + expired})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expired token: got %d, want 401", rec.Code)
	}
}

func TestLogoutRevokesToken(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "kojo.owusu@school.gh", "student123")
	rec := do(r, "POST", "/auth/logout", "", map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusOK {
		t.Fatalf("logout: %d", rec.Code)
	}
	rec = do(r, "GET", "/auth/me", "", map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("reusing revoked token: got %d, want 401", rec.Code)
	}
}

func TestRoleGuard(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "kojo.owusu@school.gh", "student123")
	// students may not list accounts
	rec := do(r, "GET", "/api/users", "", map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("student listing users: got %d, want 403", rec.Code)
	}
	// ... or create assessments
	rec = do(r, "POST", "/api/assessments", `{}`, map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("student creating assessment: got %d, want 403", rec.Code)
	}
}

func TestStudentScoping(t *testing.T) {
	r := newTestServer(t, Config{})
	stuTok := login(t, r, "kojo.owusu@school.gh", "student123")
	frTok := login(t, r, "ama.owusu@school.gh", "parent123") // parent of STU-001 only

	for _, path := range []string{
		"/api/attendance/students/STU-002/history",
		"/api/attendance/students/STU-002/summary",
		"/api/gate/students/STU-002",
		"/api/analytics/students/STU-002/results",
		"/api/analytics/students/STU-002/weak-topics",
		"/api/interventions/students/STU-002",
		"/api/reports/students/STU-002/report-card",
	} {
		rec := do(r, "GET", path, "", map[string]string{"Authorization": "Bearer " + stuTok})
		if rec.Code != http.StatusForbidden {
			t.Fatalf("student %s: got %d, want 403", path, rec.Code)
		}
		rec = do(r, "GET", path, "", map[string]string{"Authorization": "Bearer " + frTok})
		if rec.Code != http.StatusForbidden {
			t.Fatalf("parent %s: got %d, want 403", path, rec.Code)
		}
	}
	// staff may read the same endpoints
	teachTok := login(t, r, "efua.mensah@school.gh", "teacher123")
	rec := do(r, "GET", "/api/attendance/students/STU-002/history", "", map[string]string{"Authorization": "Bearer " + teachTok})
	if rec.Code != http.StatusOK {
		t.Fatalf("teacher history: got %d, want 200", rec.Code)
	}
	// student may read their own records
	rec = do(r, "GET", "/api/analytics/students/STU-001/results", "", map[string]string{"Authorization": "Bearer " + stuTok})
	if rec.Code != http.StatusOK {
		t.Fatalf("student own results: got %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
}

func TestCheckInIsSelfOnlyForStudents(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "kojo.owusu@school.gh", "student123")
	body := `{"studentId":"STU-002","classId":"JHS2A","time":"07:30"}`
	rec := do(r, "POST", "/api/attendance/check-in", body, map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("student checking in another student: got %d, want 403", rec.Code)
	}
	body = `{"studentId":"STU-001","classId":"JHS2A","time":"07:30"}`
	rec = do(r, "POST", "/api/attendance/check-in", body, map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusOK && rec.Code != http.StatusCreated {
		t.Fatalf("student self check-in: got %d, want 200/201", rec.Code)
	}
}

func TestOversizedBodyRejected(t *testing.T) {
	r := newTestServer(t, Config{})
	big := `{"email":"` + strings.Repeat("a", 2<<20) + `"}`
	rec := do(r, "POST", "/auth/login", big, nil)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized body: got %d, want 413", rec.Code)
	}
}

func TestSecurityHeaders(t *testing.T) {
	r := newTestServer(t, Config{})
	rec := do(r, "GET", "/health", "", nil)
	for _, h := range []string{"X-Content-Type-Options", "X-Frame-Options", "Referrer-Policy"} {
		if rec.Header().Get(h) == "" {
			t.Fatalf("missing header %s", h)
		}
	}
	rec = do(r, "POST", "/auth/login", `{"email":"a@b.c","password":"x"}`, nil)
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Fatalf("auth response must be no-store, got %q", cc)
	}
}

func TestCORSOriginAllowList(t *testing.T) {
	r := newTestServer(t, Config{AllowedOrigins: []string{"https://app.example.com"}})

	rec := do(r, "GET", "/health", "", map[string]string{"Origin": "https://app.example.com"})
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "https://app.example.com" {
		t.Fatalf("allowed origin not echoed: %q", got)
	}

	rec = do(r, "GET", "/health", "", map[string]string{"Origin": "https://evil.example.net"})
	if rec.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("disallowed origin must not get CORS headers")
	}

	rec = do(r, "OPTIONS", "/auth/login", "", map[string]string{
		"Origin":                        "https://app.example.com",
		"Access-Control-Request-Method": "POST",
	})
	if rec.Code != http.StatusNoContent {
		t.Fatalf("preflight: got %d, want 204", rec.Code)
	}
}

func TestProductionRequiresSecret(t *testing.T) {
	if _, err := NewServer(store.New(), Config{Production: true}); err == nil {
		t.Fatal("production must refuse a missing secret")
	}
	s, err := NewServer(store.New(), Config{Secret: "unit-test-secret-key", Production: true})
	if err != nil {
		t.Fatalf("production with secret: %v", err)
	}
	if len(s.secret) == 0 {
		t.Fatal("secret not stored")
	}
}

func TestCreateUserValidation(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "admin@solvanta.app", "admin123")
	auth := map[string]string{"Authorization": "Bearer " + tok}

	// weak password rejected
	rec := do(r, "POST", "/api/users", `{"name":"A B","email":"x@school.gh","password":"short","role":"teacher"}`, auth)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("weak password: got %d, want 400", rec.Code)
	}
	// bad email rejected
	rec = do(r, "POST", "/api/users", `{"name":"A B","email":"nope","password":"Teacher123","role":"teacher"}`, auth)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("bad email: got %d, want 400", rec.Code)
	}
	// duplicate email rejected
	rec = do(r, "POST", "/api/users", `{"name":"A B","email":"admin@solvanta.app","password":"Teacher123","role":"teacher"}`, auth)
	if rec.Code != http.StatusConflict {
		t.Fatalf("duplicate email: got %d, want 409", rec.Code)
	}
	// valid creation → login with the new account
	rec = do(r, "POST", "/api/users", `{"name":"Kofi Ame","email":"kofi.ame@school.gh","password":"Teacher123","role":"teacher","classId":"JHS1A"}`, auth)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create user: got %d %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "$2") {
		t.Fatal("create user response leaked a bcrypt hash")
	}
	login(t, r, "kofi.ame@school.gh", "Teacher123")
}

func TestChangePassword(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "kojo.owusu@school.gh", "student123")
	auth := map[string]string{"Authorization": "Bearer " + tok}

	rec := do(r, "PATCH", "/api/users/USR-STU-001/password", `{"current":"wrongCurrent","new":"SecureNew1"}`, auth)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong current password: got %d, want 401", rec.Code)
	}

	rec = do(r, "PATCH", "/api/users/USR-STU-001/password", `{"current":"student123","new":"SecureNew1"}`, auth)
	if rec.Code != http.StatusOK {
		t.Fatalf("password change: got %d %s", rec.Code, rec.Body.String())
	}

	// the token used for the change must now be revoked
	rec = do(r, "GET", "/auth/me", "", auth)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("token after password change: got %d, want 401", rec.Code)
	}

	// old password must no longer work
	rec = do(r, "POST", "/auth/login", `{"email":"kojo.owusu@school.gh","password":"student123"}`, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("old password login: got %d, want 401", rec.Code)
	}

	// new password works
	login(t, r, "kojo.owusu@school.gh", "SecureNew1")
}

func TestUserListHidesPasswords(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "admin@solvanta.app", "admin123")
	rec := do(r, "GET", "/api/users", "", map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusOK {
		t.Fatalf("list users: %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "password") {
		t.Fatalf("password field leaked in user list: %s", rec.Body.String())
	}
}
