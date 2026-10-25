package httpapi

import (
	"encoding/json"
	"math"
	"net/http"
	"strings"
	"testing"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// =============================================================================
// Marks recording — a paper's score is captured, marked and reported intact
// =============================================================================
//
// ASSMT-MAT-HALF in the seed: Q-MATH-001 (MCQ, 2 marks, "2/4"), Q-MATH-002
// (MCQ, 3 marks, "3/8 m") and Q-MATH-003 (worked maths, 4 marks, teacher
// verdict). Total 9.

// addPupil puts a fresh pupil in classID so a test starts from no submission.
func addPupil(t *testing.T, st store.Store, id, classID string) {
	t.Helper()
	if err := st.SaveStudent(domain.Student{ID: id, FirstName: "Test", LastName: id,
		ClassID: classID, SchoolID: "SCH-001", ParentUserID: "USR-PRN-001"}); err != nil {
		t.Fatal(err)
	}
}

func TestMarksAreRecordedThroughTheWholeFlow(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	addPupil(t, st, "STU-MARKS", "JHS2A")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// Capture: Q1 right, Q2 wrong. The body's classId must not move the
	// result into another class's analytics.
	rec := do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/submit",
		`{"studentId":"STU-MARKS","classId":"JHS1B","answers":{"Q-MATH-001":" 2/4 ","Q-MATH-002":"1/4 m","Q-MATH-003":"11/12"}}`, teacher)
	if rec.Code != http.StatusCreated {
		t.Fatalf("submit: %d %s", rec.Code, rec.Body.String())
	}
	var submitted struct {
		Submission      domain.Submission `json:"submission"`
		AutoMarked      float64           `json:"autoMarked"`
		PendingVerdicts []string          `json:"pendingVerdicts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &submitted); err != nil {
		t.Fatal(err)
	}
	if submitted.AutoMarked != 2 {
		t.Errorf("auto-marked = %v, want 2", submitted.AutoMarked)
	}
	if submitted.Submission.ClassID != "JHS2A" {
		t.Errorf("class = %q, want the pupil's own JHS2A", submitted.Submission.ClassID)
	}
	if len(submitted.PendingVerdicts) != 1 || submitted.PendingVerdicts[0] != "Q-MATH-003" {
		t.Errorf("pending verdicts = %v, want [Q-MATH-003]", submitted.PendingVerdicts)
	}

	// Verdict: a half mark must survive, and the earned total include it.
	rec = do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/verdicts",
		`{"studentId":"STU-MARKS","teacherMarks":{"Q-MATH-003":3.5}}`, teacher)
	if rec.Code != http.StatusOK {
		t.Fatalf("verdicts: %d %s", rec.Code, rec.Body.String())
	}
	sub, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-MARKS")
	if sub.Earned != 5.5 || sub.TeacherMarks["Q-MATH-003"] != 3.5 {
		t.Errorf("stored earned = %v, marks = %v; want 5.5 with Q3 = 3.5", sub.Earned, sub.TeacherMarks)
	}

	// The parent is told the real score, half mark included.
	found := false
	for _, n := range st.Notifications() {
		if n.StudentID == "STU-MARKS" && strings.Contains(n.Body, "5.5/9") {
			found = true
		}
	}
	if !found {
		t.Error("no parent notification reporting 5.5/9")
	}

	// Results report the same number and the grade it implies.
	rec = do(r, "GET", "/api/assessments/ASSMT-MAT-HALF/results", "", teacher)
	var results struct {
		Rows []struct {
			Student domain.Student `json:"student"`
			Earned  float64        `json:"earned"`
			Percent float64        `json:"percent"`
			Grade   string         `json:"grade"`
		} `json:"rows"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &results); err != nil {
		t.Fatal(err)
	}
	var got bool
	for _, row := range results.Rows {
		if row.Student.ID == "STU-MARKS" {
			got = true
			if row.Earned != 5.5 || math.Abs(row.Percent-100*5.5/9) > 1e-9 || row.Grade != "C" {
				t.Errorf("results row = %+v, want 5.5 / 61.1%% / C", row)
			}
		}
	}
	if !got {
		t.Error("pupil missing from results")
	}

	// A verdict above the question's marks is capped, not recorded as given.
	do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/verdicts",
		`{"studentId":"STU-MARKS","teacherMarks":{"Q-MATH-003":99}}`, teacher)
	if sub, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-MARKS"); sub.Earned != 6 {
		t.Errorf("earned after an over-max verdict = %v, want 6 (2 + capped 4)", sub.Earned)
	}
}

// TestPupilCannotOverwriteAMarkedPaper: a resubmission replaces the whole row,
// so a pupil (or their outbox replaying an old submit) would wipe the
// teacher's verdicts and the score with them.
func TestPupilCannotOverwriteAMarkedPaper(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	before, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-001")
	if before.TeacherMarks["Q-MATH-003"] != 3 {
		t.Fatalf("seed changed: %+v", before)
	}
	pupil := bearer(login(t, r, "kojo.owusu@school.gh", "student123"))
	rec := do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/submit", `{"answers":{}}`, pupil)
	if rec.Code != http.StatusConflict {
		t.Errorf("resubmit: got %d, want 409", rec.Code)
	}
	after, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-001")
	if after.Earned != before.Earned || after.TeacherMarks["Q-MATH-003"] != 3 {
		t.Errorf("marked paper changed: before %+v, after %+v", before, after)
	}
}

// TestTeachersCaptureAndMarkTheirOwnClass: a teacher works on their own class
// only; a headteacher on any.
func TestTeachersCaptureAndMarkTheirOwnClass(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	addPupil(t, st, "STU-OTHER", "JHS1B")
	if err := st.SaveAssessment(domain.Assessment{ID: "ASSMT-OTHER", Title: "Other class test",
		Type: domain.TypeClassTest, SubjectID: "MATH", ClassID: "JHS1B",
		Questions: []domain.Question{{ID: "Q-O1", Type: domain.QTypeMath, Marks: 4}}}); err != nil {
		t.Fatal(err)
	}
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))
	head := bearer(login(t, r, "head@school.gh", "head123"))

	submit := `{"studentId":"STU-OTHER","answers":{"Q-O1":"x"}}`
	if rec := do(r, "POST", "/api/assessments/ASSMT-OTHER/submit", submit, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("teacher capturing another class: got %d, want 403", rec.Code)
	}
	if rec := do(r, "POST", "/api/assessments/ASSMT-OTHER/submit", submit, head); rec.Code != http.StatusCreated {
		t.Fatalf("head capturing: got %d %s", rec.Code, rec.Body.String())
	}
	verdict := `{"studentId":"STU-OTHER","teacherMarks":{"Q-O1":2}}`
	if rec := do(r, "POST", "/api/assessments/ASSMT-OTHER/verdicts", verdict, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("teacher marking another class: got %d, want 403", rec.Code)
	}
	if rec := do(r, "POST", "/api/assessments/ASSMT-OTHER/verdicts", verdict, head); rec.Code != http.StatusOK {
		t.Errorf("head marking: got %d %s", rec.Code, rec.Body.String())
	}
}
