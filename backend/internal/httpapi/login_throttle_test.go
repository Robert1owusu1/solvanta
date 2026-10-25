package httpapi

import (
	"net/http"
	"testing"
)

// =============================================================================
// Login throttle in a school setting
// =============================================================================
//
// A whole classroom usually reaches the server from one school IP, and behind
// a hosting proxy every visitor would share the proxy's IP unless it is
// trusted. TestLoginRateLimit (security_test.go) still pins the guessing cap;
// these pin that real sign-ins are not caught by it.

const badLogin = `{"email":"kojo.owusu@school.gh","password":"nopeNope1"}`

func TestAClassroomCanSignInFromOneIP(t *testing.T) {
	r := newTestServer(t, Config{})
	for i := 0; i < 30; i++ {
		if rec := do(r, "POST", "/auth/login", `{"email":"kojo.owusu@school.gh","password":"student123"}`, nil); rec.Code != http.StatusOK {
			t.Fatalf("sign-in %d from the shared IP: got %d", i+1, rec.Code)
		}
	}
	// Successful sign-ins gave their slots back; guessing is still capped.
	for i := 0; i < 10; i++ {
		if rec := do(r, "POST", "/auth/login", badLogin, nil); rec.Code != http.StatusUnauthorized {
			t.Fatalf("failed attempt %d: got %d, want 401", i+1, rec.Code)
		}
	}
	if rec := do(r, "POST", "/auth/login", badLogin, nil); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("11th failure: got %d, want 429", rec.Code)
	}
}

func TestForwardedForIsIgnoredUnlessTheProxyIsTrusted(t *testing.T) {
	// Untrusted: a client cannot reset its own throttle with a fake header.
	r := newTestServer(t, Config{})
	for i := 0; i < 10; i++ {
		do(r, "POST", "/auth/login", badLogin, map[string]string{"X-Forwarded-For": "198.51.100." + itoa(i+1)})
	}
	if rec := do(r, "POST", "/auth/login", badLogin, map[string]string{"X-Forwarded-For": "198.51.100.99"}); rec.Code != http.StatusTooManyRequests {
		t.Errorf("spoofed X-Forwarded-For bypassed the throttle: got %d, want 429", rec.Code)
	}

	// Trusted (httptest's peer address is 192.0.2.1): each visitor behind the
	// proxy is throttled on their own address.
	r = newTestServer(t, Config{TrustedProxies: []string{"192.0.2.1"}})
	for i := 0; i < 10; i++ {
		do(r, "POST", "/auth/login", badLogin, map[string]string{"X-Forwarded-For": "198.51.100.1"})
	}
	if rec := do(r, "POST", "/auth/login", badLogin, map[string]string{"X-Forwarded-For": "198.51.100.1"}); rec.Code != http.StatusTooManyRequests {
		t.Errorf("visitor past the cap: got %d, want 429", rec.Code)
	}
	if rec := do(r, "POST", "/auth/login", badLogin, map[string]string{"X-Forwarded-For": "198.51.100.2"}); rec.Code != http.StatusUnauthorized {
		t.Errorf("a different visitor behind the same proxy: got %d, want 401", rec.Code)
	}
}

func TestInvalidTrustedProxyStopsTheServer(t *testing.T) {
	if _, err := NewServer(nil, Config{TrustedProxies: []string{"not-an-ip"}}); err == nil {
		t.Error("NewServer accepted an invalid TRUSTED_PROXIES entry")
	}
	if _, err := NewServer(nil, Config{TrustedProxies: []string{"10.0.0.0/8", "192.0.2.1"}}); err != nil {
		t.Errorf("valid entries refused: %v", err)
	}
}
