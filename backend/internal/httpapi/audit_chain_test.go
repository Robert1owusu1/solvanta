package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestAuditVerifyEndpointReportsIntactChain(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	admin := bearer(login(t, r, "admin@solvanta.app", "admin123"))
	// Generate a few audited actions.
	do(r, "GET", "/api/audit", "", admin)
	do(r, "PUT", "/api/school/classes/JHS9X", `{"name":"JHS 9","stream":"X"}`, admin)

	rec := do(r, "GET", "/api/audit/verify", "", admin)
	if rec.Code != http.StatusOK {
		t.Fatalf("verify: %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Valid    bool `json:"valid"`
		Entries  int  `json:"entries"`
		BrokenAt int  `json:"brokenAt"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	if !out.Valid || out.Entries < 1 || out.BrokenAt != -1 {
		t.Errorf("chain should be intact: %+v", out)
	}
}
