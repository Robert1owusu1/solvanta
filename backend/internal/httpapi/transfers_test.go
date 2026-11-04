package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"

	"solvanta/backend/internal/domain"
)

// seedWorkspace registers an independent teacher and fills the workspace with
// one class, one pupil, one score-only assessment and one manual score.
func seedWorkspace(t *testing.T, r http.Handler, email string) (map[string]string, string) {
	t.Helper()
	tok, reg := registerIndependent(t, r, email)
	if rec := do(r, "PUT", "/api/school/classes/JHS1A", `{"name":"JHS 1","stream":"A"}`, tok); rec.Code != http.StatusOK {
		t.Fatalf("class: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "POST", "/api/students",
		`{"id":"STU-W1","firstName":"Ama","lastName":"K","gender":"F","classId":"JHS1A","admissionNo":"W-001"}`, tok); rec.Code != http.StatusCreated {
		t.Fatalf("student: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "POST", "/api/assessments",
		`{"id":"ASSMT-W1","title":"Paper Test","type":"classTest","subjectId":"MATH","classId":"JHS1A","maxScore":10}`, tok); rec.Code != http.StatusCreated {
		t.Fatalf("assessment: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "PUT", "/api/assessments/ASSMT-W1/scores/STU-W1", `{"score":8}`, tok); rec.Code != http.StatusOK {
		t.Fatalf("score: %d %s", rec.Code, rec.Body.String())
	}
	return tok, reg.SchoolID
}

type previewResp struct {
	Counts struct {
		Classes     int `json:"classes"`
		Students    int `json:"students"`
		Assessments int `json:"assessments"`
		Scores      int `json:"scores"`
	} `json:"counts"`
	Conflicts []struct {
		Kind string `json:"kind"`
		ID   string `json:"id"`
	} `json:"conflicts"`
}

func TestWorkspaceTransfer(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	super := bearer(login(t, r, "super@solvanta.app", "super123"))
	teacherTok, ws := seedWorkspace(t, r, "move@teach.gh")

	if rec := do(r, "POST", "/api/schools", `{"id":"SCH-NEW","name":"New School"}`, super); rec.Code != http.StatusCreated {
		t.Fatalf("create target: %d %s", rec.Code, rec.Body.String())
	}

	// Preview is accurate and writes nothing.
	rec := do(r, "POST", "/api/schools/SCH-NEW/transfers/preview", `{"sourceSchoolId":"`+ws+`"}`, super)
	if rec.Code != http.StatusOK {
		t.Fatalf("preview: %d %s", rec.Code, rec.Body.String())
	}
	var pv previewResp
	_ = json.Unmarshal(rec.Body.Bytes(), &pv)
	if pv.Counts.Classes != 1 || pv.Counts.Students != 1 || pv.Counts.Assessments != 1 || pv.Counts.Scores != 1 {
		t.Errorf("preview counts = %+v, want 1/1/1/1", pv.Counts)
	}
	if len(pv.Conflicts) != 0 {
		t.Errorf("unexpected conflicts into an empty school: %+v", pv.Conflicts)
	}

	// Only the super admin may transfer.
	if rec := do(r, "POST", "/api/schools/SCH-NEW/transfers/preview", `{"sourceSchoolId":"`+ws+`"}`, teacherTok); rec.Code != http.StatusForbidden {
		t.Errorf("teacher preview: got %d want 403", rec.Code)
	}

	// Execute.
	rec = do(r, "POST", "/api/schools/SCH-NEW/transfers", `{"sourceSchoolId":"`+ws+`"}`, super)
	if rec.Code != http.StatusOK {
		t.Fatalf("execute: %d %s", rec.Code, rec.Body.String())
	}
	var ex struct {
		Archived bool `json:"archived"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &ex)
	if !ex.Archived {
		t.Error("workspace not archived after transfer")
	}

	// The teacher is now a normal teacher in the destination school.
	teacher2 := bearer(login(t, r, "move@teach.gh", "Teacher#12345"))
	rec = do(r, "GET", "/auth/me", "", teacher2)
	var me struct {
		User domain.User `json:"user"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &me)
	if me.User.Role != domain.RoleTeacher || me.User.SchoolID != "SCH-NEW" {
		t.Errorf("teacher after move = role %q school %q, want teacher/SCH-NEW", me.User.Role, me.User.SchoolID)
	}

	// The pupil moved into the school.
	rec = do(r, "GET", "/api/students?schoolId=SCH-NEW", "", super)
	var students []domain.Student
	_ = json.Unmarshal(rec.Body.Bytes(), &students)
	var moved bool
	for _, st := range students {
		if st.AdmissionNo == "W-001" {
			moved = true
		}
	}
	if !moved {
		t.Error("the workspace pupil did not land in the destination school")
	}

	// The archived workspace is read-only (writes refused) but still readable.
	if rec := do(r, "PUT", "/api/school/classes/JHS9Z?schoolId="+ws, `{"name":"x"}`, super); rec.Code != http.StatusForbidden {
		t.Errorf("write to archived workspace: got %d want 403", rec.Code)
	}
	if rec := do(r, "GET", "/api/students?schoolId="+ws, "", super); rec.Code != http.StatusOK {
		t.Errorf("read archived workspace: got %d want 200", rec.Code)
	}

	// A second transfer is refused.
	if rec := do(r, "POST", "/api/schools/SCH-NEW/transfers", `{"sourceSchoolId":"`+ws+`"}`, super); rec.Code != http.StatusConflict {
		t.Errorf("double transfer: got %d want 409", rec.Code)
	}
}

func TestWorkspaceTransferMergeConflict(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	super := bearer(login(t, r, "super@solvanta.app", "super123"))
	_, ws := seedWorkspace(t, r, "merge@teach.gh")

	do(r, "POST", "/api/schools", `{"id":"SCH-MRG","name":"Merge School"}`, super)
	// A class with the SAME id already exists in the destination.
	do(r, "PUT", "/api/school/classes/JHS1A?schoolId=SCH-MRG", `{"name":"JHS 1","stream":"A"}`, super)

	rec := do(r, "POST", "/api/schools/SCH-MRG/transfers/preview", `{"sourceSchoolId":"`+ws+`"}`, super)
	var pv previewResp
	_ = json.Unmarshal(rec.Body.Bytes(), &pv)
	var clash bool
	for _, c := range pv.Conflicts {
		if c.Kind == "classNameClash" && c.ID == "JHS1A" {
			clash = true
		}
	}
	if !clash {
		t.Fatalf("expected a classNameClash on JHS1A, got %+v", pv.Conflicts)
	}

	// Merge folds the pupil into the existing class, keeping its id.
	body := `{"sourceSchoolId":"` + ws + `","classDecisions":{"JHS1A":"merge"}}`
	if rec := do(r, "POST", "/api/schools/SCH-MRG/transfers", body, super); rec.Code != http.StatusOK {
		t.Fatalf("merge execute: %d %s", rec.Code, rec.Body.String())
	}
	rec = do(r, "GET", "/api/students?schoolId=SCH-MRG", "", super)
	var students []domain.Student
	_ = json.Unmarshal(rec.Body.Bytes(), &students)
	var inJHS1A bool
	for _, st := range students {
		if st.AdmissionNo == "W-001" && st.ClassID == "JHS1A" {
			inJHS1A = true
		}
	}
	if !inJHS1A {
		t.Errorf("merged pupil not in the existing JHS1A: %+v", students)
	}
}
