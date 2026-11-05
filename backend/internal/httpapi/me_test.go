package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestMeExportIncludesOwnData(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	parent := bearer(login(t, r, "ama.owusu@school.gh", "parent123"))

	rec := do(r, "GET", "/api/me/export", "", parent)
	if rec.Code != http.StatusOK {
		t.Fatalf("export: %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Account  map[string]any   `json:"account"`
		Students []map[string]any `json:"students"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	if out.Account["email"] != "ama.owusu@school.gh" {
		t.Errorf("account = %v, want the parent's own", out.Account["email"])
	}
	// The password must never be exported.
	if _, leaked := out.Account["password"]; leaked {
		t.Error("export leaked the password field")
	}
	if len(out.Students) == 0 {
		t.Error("parent export should include their child's records")
	}
}

func TestMeDeleteGuardsAndErases(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})

	// The platform operator cannot self-delete.
	super := bearer(login(t, r, "super@solvanta.app", "super123"))
	if rec := do(r, "DELETE", "/api/me", `{"password":"super123"}`, super); rec.Code != http.StatusConflict {
		t.Errorf("super self-delete: got %d want 409", rec.Code)
	}

	// The only school admin cannot delete (would lock the school out).
	admin := bearer(login(t, r, "admin@solvanta.app", "admin123"))
	if rec := do(r, "DELETE", "/api/me", `{"password":"admin123"}`, admin); rec.Code != http.StatusConflict {
		t.Errorf("last admin self-delete: got %d want 409 (%s)", rec.Code, rec.Body.String())
	}

	// A parent can erase their own account — but not with a wrong password.
	parent := bearer(login(t, r, "ama.owusu@school.gh", "parent123"))
	if rec := do(r, "DELETE", "/api/me", `{"password":"wrong"}`, parent); rec.Code != http.StatusUnauthorized {
		t.Errorf("wrong password: got %d want 401", rec.Code)
	}
	if rec := do(r, "DELETE", "/api/me", `{"password":"parent123"}`, parent); rec.Code != http.StatusOK {
		t.Fatalf("erase: %d %s", rec.Code, rec.Body.String())
	}
	// The account is gone and the session is revoked.
	if _, ok := st.UserByEmail("ama.owusu@school.gh"); ok {
		t.Error("the account still exists after erasure")
	}
	if rec := do(r, "GET", "/auth/me", "", parent); rec.Code != http.StatusUnauthorized {
		t.Errorf("revoked session still works: got %d want 401", rec.Code)
	}
	// Signing in again fails.
	if rec := do(r, "POST", "/auth/login", `{"email":"ama.owusu@school.gh","password":"parent123"}`, nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("deleted account can still sign in: got %d want 401", rec.Code)
	}
}
