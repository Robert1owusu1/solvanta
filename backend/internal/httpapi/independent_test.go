package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"

	"solvanta/backend/internal/domain"
)

type regResp struct {
	Token    string      `json:"token"`
	User     domain.User `json:"user"`
	SchoolID string      `json:"schoolId"`
}

// registerIndependent self-registers an independent teacher and returns its
// bearer header, user id and workspace id.
func registerIndependent(t *testing.T, r http.Handler, email string) (map[string]string, regResp) {
	t.Helper()
	body := `{"name":"Indie Teacher","email":"` + email +
		`","password":"Teacher#12345","independent":true,"acceptDataProtection":true}`
	rec := do(r, "POST", "/auth/register", body, nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("register: %d %s", rec.Code, rec.Body.String())
	}
	var resp regResp
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	return bearer(resp.Token), resp
}

func TestIndependentRegistrationCreatesOwnWorkspace(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	tok, resp := registerIndependent(t, r, "indie@teach.gh")

	if resp.SchoolID == "" || resp.SchoolID == domain.DefaultSchoolID() {
		t.Fatalf("workspace id = %q, want a fresh id (not the default school)", resp.SchoolID)
	}
	if resp.User.Role != domain.RoleSchoolAdmin || resp.User.SchoolID != resp.SchoolID {
		t.Errorf("owner = %+v, want schoolAdmin in their own workspace", resp.User)
	}

	// The workspace school is independent, owned, with the privacy notice stamped.
	rec := do(r, "GET", "/api/school", "", tok)
	var school domain.School
	_ = json.Unmarshal(rec.Body.Bytes(), &school)
	if school.Kind != domain.SchoolKindIndependent || school.OwnerUserID != resp.User.ID {
		t.Errorf("school = %+v, want independent owned by %s", school, resp.User.ID)
	}
	if school.DataProtectionAcceptedAt == "" {
		t.Error("data-protection acceptance was not stored")
	}

	// Isolation: the default school's pupils are not visible here.
	rec = do(r, "GET", "/api/students", "", tok)
	var students []domain.Student
	_ = json.Unmarshal(rec.Body.Bytes(), &students)
	for _, st := range students {
		if st.ID == "STU-001" {
			t.Fatal("default school's STU-001 leaked into the independent workspace")
		}
	}
}

func TestIndependentRegistrationValidation(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	// Not accepting the data-protection notice is refused.
	noConsent := `{"name":"X","email":"x@teach.gh","password":"Teacher#12345","independent":true}`
	if rec := do(r, "POST", "/auth/register", noConsent, nil); rec.Code != http.StatusBadRequest {
		t.Errorf("no consent: got %d want 400 (%s)", rec.Code, rec.Body.String())
	}
	// A second registration with the same email is a conflict.
	registerIndependent(t, r, "dup@teach.gh")
	again := `{"name":"Y","email":"dup@teach.gh","password":"Teacher#12345","independent":true,"acceptDataProtection":true}`
	if rec := do(r, "POST", "/auth/register", again, nil); rec.Code != http.StatusConflict {
		t.Errorf("duplicate email: got %d want 409", rec.Code)
	}
}

func TestIndependentWorkspaceCapabilityMatrix(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	tok, _ := registerIndependent(t, r, "caps@teach.gh")

	// School-only modules are closed on the API (403), matching the hidden grid.
	denied := []struct {
		method, path, body string
	}{
		{"GET", "/api/audit", ""},
		{"GET", "/api/gate/events", ""},
		{"POST", "/api/payments", `{"id":"P1","invoiceId":"INV","amount":1,"method":"cash","paidAt":"2026-10-01 10:00"}`},
		{"POST", "/api/users", `{"name":"N","email":"n@x.gh","password":"Teacher#12345","role":"teacher"}`},
		{"POST", "/api/announcements", `{"title":"t","body":"b","audience":"school"}`},
		{"PUT", "/api/sms/settings", `{}`},
		{"PUT", "/api/records/term_reports/TR-1", `{"id":"TR-1"}`},
	}
	for _, d := range denied {
		if rec := do(r, d.method, d.path, d.body, tok); rec.Code != http.StatusForbidden {
			t.Errorf("%s %s in independent workspace: got %d want 403", d.method, d.path, rec.Code)
		}
	}

	// Classroom actions are allowed, exam types included (the exam-type
	// restriction only applies inside schools).
	if rec := do(r, "PUT", "/api/school/classes/JHS1A", `{"name":"JHS 1","stream":"A"}`, tok); rec.Code != http.StatusOK {
		t.Fatalf("create class: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "POST", "/api/students", `{"firstName":"Ama","lastName":"K","gender":"F","classId":"JHS1A"}`, tok); rec.Code != http.StatusCreated {
		t.Errorf("register student: %d %s", rec.Code, rec.Body.String())
	}
	exam := `{"title":"End of Term","type":"endTerm","subjectId":"MATH","classId":"JHS1A","maxScore":20}`
	if rec := do(r, "POST", "/api/assessments", exam, tok); rec.Code != http.StatusCreated {
		t.Errorf("create exam assessment: %d %s", rec.Code, rec.Body.String())
	}
}
