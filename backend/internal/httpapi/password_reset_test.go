package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

// captureEmail records the last email instead of sending it.
type captureEmail struct {
	to, subject, body string
	sent              int
}

func (c *captureEmail) Name() string { return "test" }
func (c *captureEmail) Send(_ context.Context, to, subject, body string) error {
	c.to, c.subject, c.body, c.sent = to, subject, body, c.sent+1
	return nil
}

func tokenFromEmail(body string) string {
	for _, w := range strings.Fields(body) {
		if strings.Contains(w, ".") && len(w) > 30 {
			return w
		}
	}
	return ""
}

func TestPasswordResetFlow(t *testing.T) {
	mail := &captureEmail{}
	r, _ := newTestServerWithStore(t, Config{Email: mail})

	// Unknown email: still 200 (no account enumeration), no email sent.
	if rec := do(r, "POST", "/auth/password/forgot", `{"email":"nobody@nowhere.gh"}`, nil); rec.Code != http.StatusOK {
		t.Fatalf("forgot unknown: %d", rec.Code)
	}
	if mail.sent != 0 {
		t.Error("no email should be sent for an unknown address")
	}

	// Known email: 200 and a reset email with a token.
	if rec := do(r, "POST", "/auth/password/forgot", `{"email":"efua.mensah@school.gh"}`, nil); rec.Code != http.StatusOK {
		t.Fatalf("forgot: %d", rec.Code)
	}
	if mail.sent != 1 || mail.to != "efua.mensah@school.gh" {
		t.Fatalf("expected one email to the teacher, got %+v", mail)
	}
	token := tokenFromEmail(mail.body)
	if token == "" {
		t.Fatalf("no reset token found in email body:\n%s", mail.body)
	}

	// A reset token cannot be used as a session.
	if rec := do(r, "GET", "/api/students", "", bearer(token)); rec.Code != http.StatusUnauthorized {
		t.Errorf("reset token on the API: got %d want 401", rec.Code)
	}

	// Reset the password.
	if rec := do(r, "POST", "/auth/password/reset",
		`{"token":"`+token+`","newPassword":"NewTeacher#12345"}`, nil); rec.Code != http.StatusOK {
		t.Fatalf("reset: %d %s", rec.Code, rec.Body.String())
	}

	// Old password no longer works; the new one does.
	if rec := do(r, "POST", "/auth/login", `{"email":"efua.mensah@school.gh","password":"teacher123"}`, nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("old password still works: got %d want 401", rec.Code)
	}
	if rec := do(r, "POST", "/auth/login", `{"email":"efua.mensah@school.gh","password":"NewTeacher#12345"}`, nil); rec.Code != http.StatusOK {
		t.Errorf("new password should sign in: got %d %s", rec.Code, rec.Body.String())
	}

	// The token is one-time: reusing it fails.
	if rec := do(r, "POST", "/auth/password/reset",
		`{"token":"`+token+`","newPassword":"Another#12345"}`, nil); rec.Code != http.StatusBadRequest {
		t.Errorf("token reuse: got %d want 400", rec.Code)
	}
}
