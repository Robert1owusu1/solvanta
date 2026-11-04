package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestBillingDefaultsToTestingAndSeedsPlan(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	super := bearer(login(t, r, "super@solvanta.app", "super123"))

	rec := do(r, "GET", "/api/platform/billing", "", super)
	if rec.Code != http.StatusOK {
		t.Fatalf("billing: %d %s", rec.Code, rec.Body.String())
	}
	var settings struct {
		BillingMode string `json:"billingMode"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &settings)
	if settings.BillingMode != "testing" {
		t.Errorf("default billing mode = %q, want testing", settings.BillingMode)
	}

	rec = do(r, "GET", "/api/plans", "", super)
	if !jsonContainsPlan(rec.Body.Bytes(), "plan-independent-testing") {
		t.Errorf("seed plan missing from %s", rec.Body.String())
	}
}

func jsonContainsPlan(body []byte, id string) bool {
	var plans []map[string]any
	_ = json.Unmarshal(body, &plans)
	for _, p := range plans {
		if p["id"] == id {
			return true
		}
	}
	return false
}

func TestBillingRBACSuperAdminOnly(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))
	for _, path := range []string{"/api/platform/billing", "/api/plans", "/api/platform/usage"} {
		if rec := do(r, "GET", path, "", teacher); rec.Code != http.StatusForbidden {
			t.Errorf("teacher GET %s: got %d want 403", path, rec.Code)
		}
	}
	if rec := do(r, "PUT", "/api/platform/billing", `{"billingMode":"live"}`, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("teacher PUT billing: got %d want 403", rec.Code)
	}
}

func TestTestingModeAllowsAndCountsUsage(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	super := bearer(login(t, r, "super@solvanta.app", "super123"))
	tok, reg := registerIndependent(t, r, "usage@teach.gh")

	// Assign a plan that forbids everything and allows no students — in testing
	// mode it must NOT block.
	plan := `{"id":"plan-strict","name":"Strict","kind":"independent","features":{},"limits":{"max_students":0}}`
	if rec := do(r, "POST", "/api/plans", plan, super); rec.Code != http.StatusCreated {
		t.Fatalf("create plan: %d %s", rec.Code, rec.Body.String())
	}
	assign := `{"tenantId":"` + reg.SchoolID + `","planId":"plan-strict","status":"active"}`
	if rec := do(r, "POST", "/api/subscriptions", assign, super); rec.Code != http.StatusOK {
		t.Fatalf("assign: %d %s", rec.Code, rec.Body.String())
	}

	// Still testing mode → student creation passes despite max_students 0.
	do(r, "PUT", "/api/school/classes/JHS1A", `{"name":"JHS 1","stream":"A"}`, tok)
	if rec := do(r, "POST", "/api/students", `{"firstName":"A","lastName":"B","gender":"M","classId":"JHS1A"}`, tok); rec.Code != http.StatusCreated {
		t.Fatalf("student in testing mode: %d %s", rec.Code, rec.Body.String())
	}

	// Usage was counted even though nothing was blocked.
	rec := do(r, "GET", "/api/platform/usage", "", super)
	var rows []map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &rows)
	var peak float64 = -1
	for _, row := range rows {
		if row["tenantId"] == reg.SchoolID {
			peak = row["peakStudents"].(float64)
		}
	}
	if peak < 1 {
		t.Errorf("peak students for %s = %v, want >=1 (usage counted in testing)", reg.SchoolID, peak)
	}
}

func TestLiveModeEnforcesFeatureAndLimit(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	super := bearer(login(t, r, "super@solvanta.app", "super123"))
	tok, reg := registerIndependent(t, r, "live@teach.gh")

	// Strict plan: no features, no student headroom.
	do(r, "POST", "/api/plans",
		`{"id":"plan-strict2","name":"Strict","kind":"independent","features":{},"limits":{"max_students":0}}`, super)
	do(r, "POST", "/api/subscriptions",
		`{"tenantId":"`+reg.SchoolID+`","planId":"plan-strict2","status":"active"}`, super)
	do(r, "PUT", "/api/school/classes/JHS1A", `{"name":"JHS 1","stream":"A"}`, tok)

	// Go live immediately.
	if rec := do(r, "PUT", "/api/platform/billing", `{"billingMode":"live","graceDays":7}`, super); rec.Code != http.StatusOK {
		t.Fatalf("go live: %d %s", rec.Code, rec.Body.String())
	}

	// A disabled feature (AI marking) is now blocked with an upgrade hint.
	rec := do(r, "POST", "/api/questions/ai/requests/REQ-X/generate", `{}`, tok)
	if rec.Code != http.StatusForbidden {
		t.Errorf("AI generate under a plan without it: got %d want 403", rec.Code)
	}
	var body map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body["upgrade"] != true {
		t.Errorf("expected upgrade:true in %s", rec.Body.String())
	}

	// The student limit (0) now blocks a new registration.
	if rec := do(r, "POST", "/api/students", `{"firstName":"A","lastName":"B","gender":"M","classId":"JHS1A"}`, tok); rec.Code != http.StatusForbidden {
		t.Errorf("student over limit in live mode: got %d want 403", rec.Code)
	}

	// Reading billing status still works (never blocked).
	if rec := do(r, "GET", "/api/billing/me", "", tok); rec.Code != http.StatusOK {
		t.Errorf("billing/me: got %d want 200", rec.Code)
	}
}

func TestLiveStartDateDefersEnforcement(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	super := bearer(login(t, r, "super@solvanta.app", "super123"))
	tok, reg := registerIndependent(t, r, "future@teach.gh")
	do(r, "POST", "/api/plans",
		`{"id":"plan-strict3","name":"Strict","kind":"independent","features":{},"limits":{"max_students":0}}`, super)
	do(r, "POST", "/api/subscriptions",
		`{"tenantId":"`+reg.SchoolID+`","planId":"plan-strict3","status":"active"}`, super)
	do(r, "PUT", "/api/school/classes/JHS1A", `{"name":"JHS 1","stream":"A"}`, tok)

	// Live, but not until the far future — enforcement stays off for now.
	do(r, "PUT", "/api/platform/billing", `{"billingMode":"live","liveStartDate":"2099-01-01","graceDays":7}`, super)
	if rec := do(r, "POST", "/api/students", `{"firstName":"A","lastName":"B","gender":"M","classId":"JHS1A"}`, tok); rec.Code != http.StatusCreated {
		t.Errorf("before the live start date student creation should pass: got %d %s", rec.Code, rec.Body.String())
	}
}
