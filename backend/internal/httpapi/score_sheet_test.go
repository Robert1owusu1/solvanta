package httpapi

import (
	"encoding/json"
	"math"
	"net/http"
	"testing"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// =============================================================================
// Score sheet (gradebook) — GET /api/reports/score-sheet
// =============================================================================
//
// SCI has no seed assessments in JHS2A, so these tests own the whole subject.

type sheetResp struct {
	ClassID   string `json:"classId"`
	SubjectID string `json:"subjectId"`
	Scheme    struct {
		ClassWeight float64 `json:"classWeight"`
		ExamWeight  float64 `json:"examWeight"`
	} `json:"scheme"`
	Assessments []struct {
		ID     string `json:"id"`
		IsExam bool   `json:"isExam"`
	} `json:"assessments"`
	Rows []struct {
		Student   domain.Student `json:"student"`
		HasTotal  bool           `json:"hasTotal"`
		TermTotal float64        `json:"termTotal"`
		Grade     string         `json:"grade"`
		Position  int            `json:"position"`
		Cells     []struct {
			AssessmentID string  `json:"assessmentId"`
			Present      bool    `json:"present"`
			Earned       float64 `json:"earned"`
			Absent       bool    `json:"absent"`
		} `json:"cells"`
	} `json:"rows"`
}

func sciSheetSetup(t *testing.T, st store.Store) {
	t.Helper()
	// A term that spans the dates below.
	if err := st.SaveTerm(domain.SchoolTerm{Year: "2026/2027", Name: "Term 1",
		Start: "2026-09-01", End: "2026-12-20"}); err != nil {
		t.Fatal(err)
	}
	ca, ex := 10.0, 20.0
	for _, a := range []domain.Assessment{
		{ID: "SHEET-CA", Title: "SCI Class Test", Type: domain.TypeClassTest,
			SubjectID: "SCI", ClassID: "JHS2A", Date: "2026-10-01", MaxScore: &ca},
		{ID: "SHEET-EX", Title: "SCI End of Term", Type: domain.TypeEndTerm,
			SubjectID: "SCI", ClassID: "JHS2A", Date: "2026-10-02", MaxScore: &ex},
	} {
		if err := st.SaveAssessment(a); err != nil {
			t.Fatal(err)
		}
	}
}

func TestScoreSheetWeightedTotal(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	sciSheetSetup(t, st)
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// STU-001: class work 8/10 = 80%, exam 14/20 = 70%.
	// Default scheme is 30/70 → 80*0.3 + 70*0.7 = 73.0 → grade "2".
	do(r, "PUT", "/api/assessments/SHEET-CA/scores/STU-001", `{"score":8}`, teacher)
	do(r, "PUT", "/api/assessments/SHEET-EX/scores/STU-001", `{"score":14}`, teacher)

	rec := do(r, "GET", "/api/reports/score-sheet?classId=JHS2A&subjectId=SCI", "", teacher)
	if rec.Code != http.StatusOK {
		t.Fatalf("sheet: %d %s", rec.Code, rec.Body.String())
	}
	var resp sheetResp
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Scheme.ClassWeight != 30 || resp.Scheme.ExamWeight != 70 {
		t.Errorf("scheme weights = %v/%v, want 30/70", resp.Scheme.ClassWeight, resp.Scheme.ExamWeight)
	}
	if len(resp.Assessments) != 2 {
		t.Fatalf("columns = %d, want 2", len(resp.Assessments))
	}
	var found bool
	for _, row := range resp.Rows {
		if row.Student.ID != "STU-001" {
			continue
		}
		found = true
		if !row.HasTotal || math.Abs(row.TermTotal-73) > 1e-9 {
			t.Errorf("STU-001 term total = %v, want 73", row.TermTotal)
		}
		if row.Grade != "2" {
			t.Errorf("STU-001 grade = %q, want 2", row.Grade)
		}
		if row.Position != 1 {
			t.Errorf("STU-001 position = %d, want 1 (only ranked pupil)", row.Position)
		}
		if len(row.Cells) != 2 {
			t.Errorf("STU-001 cells = %d, want 2", len(row.Cells))
		}
	}
	if !found {
		t.Fatal("STU-001 missing from the sheet")
	}
	// A pupil with no scores has no total and no position.
	for _, row := range resp.Rows {
		if row.Student.ID == "STU-002" && (row.HasTotal || row.Position != 0) {
			t.Errorf("STU-002 should be unranked with no total, got %+v", row)
		}
	}
}

func TestScoreSheetExcludesAbsentFromTotal(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	sciSheetSetup(t, st)
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// STU-002 is absent for the class test but scores full marks in the exam.
	// The absent class-work score is excluded, so the total is the exam alone
	// (100%), not dragged down by a zero.
	do(r, "PUT", "/api/assessments/SHEET-CA/scores/STU-002", `{"absent":true}`, teacher)
	do(r, "PUT", "/api/assessments/SHEET-EX/scores/STU-002", `{"score":20}`, teacher)

	rec := do(r, "GET", "/api/reports/score-sheet?classId=JHS2A&subjectId=SCI", "", teacher)
	var resp sheetResp
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	for _, row := range resp.Rows {
		if row.Student.ID != "STU-002" {
			continue
		}
		if !row.HasTotal || math.Abs(row.TermTotal-100) > 1e-9 {
			t.Errorf("STU-002 total = %v, want 100 (absent class work excluded)", row.TermTotal)
		}
		var absentCell bool
		for _, cell := range row.Cells {
			if cell.AssessmentID == "SHEET-CA" {
				absentCell = cell.Absent
			}
		}
		if !absentCell {
			t.Error("the class-test cell should be flagged absent")
		}
	}
}

func TestScoreSheetRBAC(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	sciSheetSetup(t, st)
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))
	head := bearer(login(t, r, "head@school.gh", "head123"))
	student := bearer(login(t, r, "kojo.owusu@school.gh", "student123"))
	parent := bearer(login(t, r, "ama.owusu@school.gh", "parent123"))

	// Teacher: own class only.
	if rec := do(r, "GET", "/api/reports/score-sheet?classId=JHS2A&subjectId=SCI", "", teacher); rec.Code != http.StatusOK {
		t.Errorf("teacher own class: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "GET", "/api/reports/score-sheet?classId=JHS1A&subjectId=SCI", "", teacher); rec.Code != http.StatusForbidden {
		t.Errorf("teacher other class: got %d want 403", rec.Code)
	}
	// Headteacher: any class.
	if rec := do(r, "GET", "/api/reports/score-sheet?classId=JHS1A&subjectId=SCI", "", head); rec.Code != http.StatusOK {
		t.Errorf("head any class: %d %s", rec.Code, rec.Body.String())
	}
	// Students and parents: no access (route role gate).
	for name, tok := range map[string]map[string]string{"student": student, "parent": parent} {
		if rec := do(r, "GET", "/api/reports/score-sheet?classId=JHS2A&subjectId=SCI", "", tok); rec.Code != http.StatusForbidden {
			t.Errorf("%s: got %d want 403", name, rec.Code)
		}
	}
	// Missing params → 400.
	if rec := do(r, "GET", "/api/reports/score-sheet?classId=JHS2A", "", teacher); rec.Code != http.StatusBadRequest {
		t.Errorf("missing subjectId: got %d want 400", rec.Code)
	}
}
