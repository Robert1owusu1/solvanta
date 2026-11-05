package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestMoveAllTenantsBetweenPlans(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	super := bearer(login(t, r, "super@solvanta.app", "super123"))
	_, a := registerIndependent(t, r, "a@teach.gh")
	_, b := registerIndependent(t, r, "b@teach.gh")

	// Two plans; both teachers start on plan-a.
	do(r, "POST", "/api/plans", `{"id":"plan-a","name":"A","kind":"independent"}`, super)
	do(r, "POST", "/api/plans", `{"id":"plan-b","name":"B","kind":"independent"}`, super)
	do(r, "POST", "/api/subscriptions", `{"tenantId":"`+a.SchoolID+`","planId":"plan-a","status":"active"}`, super)
	do(r, "POST", "/api/subscriptions", `{"tenantId":"`+b.SchoolID+`","planId":"plan-a","status":"active"}`, super)

	// Preview counts the affected tenants.
	rec := do(r, "GET", "/api/plans/plan-b/move?fromPlanId=plan-a", "", super)
	var prev struct {
		Affected int `json:"affected"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &prev)
	if prev.Affected != 2 {
		t.Fatalf("preview affected = %d, want 2", prev.Affected)
	}

	// Only the super admin may move.
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))
	if rec := do(r, "POST", "/api/plans/plan-b/move", `{"fromPlanId":"plan-a"}`, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("teacher move: got %d want 403", rec.Code)
	}

	// Execute: both move to plan-b.
	rec = do(r, "POST", "/api/plans/plan-b/move", `{"fromPlanId":"plan-a"}`, super)
	var moved struct {
		Moved int `json:"moved"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &moved)
	if moved.Moved != 2 {
		t.Fatalf("moved = %d, want 2 (%s)", moved.Moved, rec.Body.String())
	}

	// A second preview now shows none left on plan-a.
	rec = do(r, "GET", "/api/plans/plan-b/move?fromPlanId=plan-a", "", super)
	_ = json.Unmarshal(rec.Body.Bytes(), &prev)
	if prev.Affected != 0 {
		t.Errorf("after move, plan-a still has %d", prev.Affected)
	}
}
