package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"solvanta/backend/internal/security"
)

func TestMFAEnrolAndChallengeFlow(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// Setup → a secret and otpauth URI; MFA is not active yet.
	rec := do(r, "POST", "/auth/mfa/setup", "", teacher)
	if rec.Code != http.StatusOK {
		t.Fatalf("setup: %d %s", rec.Code, rec.Body.String())
	}
	var setup struct {
		Secret     string `json:"secret"`
		OtpauthURI string `json:"otpauthUri"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &setup)
	if setup.Secret == "" || setup.OtpauthURI == "" {
		t.Fatalf("setup response = %+v", setup)
	}

	code := func() string {
		c, _ := security.TOTPCode(setup.Secret, time.Now())
		return c
	}

	// A wrong code does not enable it.
	if rec := do(r, "POST", "/auth/mfa/enable", `{"code":"000000"}`, teacher); rec.Code != http.StatusBadRequest {
		t.Errorf("enable with bad code: got %d want 400", rec.Code)
	}
	// The right code enables it.
	if rec := do(r, "POST", "/auth/mfa/enable", `{"code":"`+code()+`"}`, teacher); rec.Code != http.StatusOK {
		t.Fatalf("enable: %d %s", rec.Code, rec.Body.String())
	}

	// Signing in now returns a challenge, not a session token.
	rec = do(r, "POST", "/auth/login", `{"email":"efua.mensah@school.gh","password":"teacher123"}`, nil)
	var challenge struct {
		MFARequired bool   `json:"mfaRequired"`
		MFAToken    string `json:"mfaToken"`
		Token       string `json:"token"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &challenge)
	if !challenge.MFARequired || challenge.MFAToken == "" || challenge.Token != "" {
		t.Fatalf("login with MFA on = %+v, want a challenge and no token", challenge)
	}

	// The challenge token cannot reach the API.
	if rec := do(r, "GET", "/api/students", "", bearer(challenge.MFAToken)); rec.Code != http.StatusUnauthorized {
		t.Errorf("challenge token on the API: got %d want 401", rec.Code)
	}

	// Verify with a wrong code fails.
	if rec := do(r, "POST", "/auth/mfa/verify",
		`{"mfaToken":"`+challenge.MFAToken+`","code":"000000"}`, nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("verify bad code: got %d want 401", rec.Code)
	}
	// Verify with the right code yields a working session.
	rec = do(r, "POST", "/auth/mfa/verify",
		`{"mfaToken":"`+challenge.MFAToken+`","code":"`+code()+`"}`, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("verify: %d %s", rec.Code, rec.Body.String())
	}
	var verified struct {
		Token string `json:"token"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &verified)
	if rec := do(r, "GET", "/api/students", "", bearer(verified.Token)); rec.Code != http.StatusOK {
		t.Errorf("verified session on the API: got %d want 200 (%s)", rec.Code, rec.Body.String())
	}

	// Disabling needs a current code; afterwards login is single-step again.
	if rec := do(r, "POST", "/auth/mfa/disable", `{"code":"`+code()+`"}`, bearer(verified.Token)); rec.Code != http.StatusOK {
		t.Fatalf("disable: %d %s", rec.Code, rec.Body.String())
	}
	rec = do(r, "POST", "/auth/login", `{"email":"efua.mensah@school.gh","password":"teacher123"}`, nil)
	_ = json.Unmarshal(rec.Body.Bytes(), &challenge)
	if challenge.Token == "" {
		t.Error("after disabling MFA, login should return a token directly")
	}
}
