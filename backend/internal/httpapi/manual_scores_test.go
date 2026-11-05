package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// =============================================================================
// Manual score entry — schools that mark on paper
// =============================================================================
//
// Seed facts used below: teacher efua.mensah covers JHS2A; STU-001..STU-006
// sit in JHS2A with admission numbers S-2023-001..006; STU-007 sits in JHS1A.

// scoreOnly adds a JHS2A score-only assessment (max 20, no questions).
func scoreOnly(t *testing.T, st store.Store, id string, date string) {
	t.Helper()
	max := 20.0
	if err := st.SaveAssessment(domain.Assessment{
		ID: id, Title: "Paper Test", Type: domain.TypeClassTest,
		SubjectID: "MATH", ClassID: "JHS2A", Date: date, MaxScore: &max,
	}); err != nil {
		t.Fatal(err)
	}
}

func setMarkingMode(t *testing.T, st store.Store, mode string) {
	t.Helper()
	sc := st.School()
	sc.MarkingMode = mode
	if err := st.SaveSchool(sc); err != nil {
		t.Fatal(err)
	}
}

func TestManualScoreValidation(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-VAL", "2026-10-01")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	cases := []struct {
		name string
		body string
		want int
	}{
		{"over max", `{"score":25}`, http.StatusBadRequest},
		{"negative", `{"score":-1}`, http.StatusBadRequest},
		{"missing score, not absent", `{}`, http.StatusBadRequest},
		{"half mark", `{"score":15.5}`, http.StatusOK},
		{"at the max", `{"score":20}`, http.StatusOK},
		{"absent needs no score", `{"absent":true}`, http.StatusOK},
	}
	for _, tc := range cases {
		rec := do(r, "PUT", "/api/assessments/ASSMT-SO-VAL/scores/STU-001", tc.body, teacher)
		if rec.Code != tc.want {
			t.Errorf("%s: got %d want %d (%s)", tc.name, rec.Code, tc.want, rec.Body.String())
		}
	}
	// The half mark must have survived.
	if sub, _ := st.SubmissionFor("ASSMT-SO-VAL", "STU-001"); !sub.Absent {
		t.Errorf("last write was absent=true, got absent=%v earned=%v", sub.Absent, sub.Earned)
	}
}

func TestManualScoreStoresSourceAndRemark(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-SRC", "2026-10-01")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	rec := do(r, "PUT", "/api/assessments/ASSMT-SO-SRC/scores/STU-001",
		`{"score":12.5,"remark":"neat work"}`, teacher)
	if rec.Code != http.StatusOK {
		t.Fatalf("put: %d %s", rec.Code, rec.Body.String())
	}
	sub, _ := st.SubmissionFor("ASSMT-SO-SRC", "STU-001")
	if sub.Source != domain.SourceManual || sub.Earned != 12.5 || sub.Remark != "neat work" {
		t.Errorf("stored = %+v, want manual/12.5/'neat work'", sub)
	}
	if len(sub.Answers) != 0 {
		t.Errorf("manual submission should have empty answers, got %v", sub.Answers)
	}
}

func TestManualScoreRBAC(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-OWN", "2026-10-01")
	// An assessment in another class (JHS1A) for the cross-class check.
	max := 10.0
	if err := st.SaveAssessment(domain.Assessment{ID: "ASSMT-SO-OTHER", Title: "Other",
		Type: domain.TypeClassTest, SubjectID: "MATH", ClassID: "JHS1A", Date: "2026-10-01", MaxScore: &max}); err != nil {
		t.Fatal(err)
	}
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))
	head := bearer(login(t, r, "head@school.gh", "head123"))
	student := bearer(login(t, r, "kojo.owusu@school.gh", "student123"))
	parent := bearer(login(t, r, "ama.owusu@school.gh", "parent123"))

	// Teacher records for their own class.
	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-OWN/scores/STU-001", `{"score":10}`, teacher); rec.Code != http.StatusOK {
		t.Errorf("teacher own class: %d %s", rec.Code, rec.Body.String())
	}
	// Teacher cannot record for another class.
	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-OTHER/scores/STU-007", `{"score":5}`, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("teacher other class: got %d want 403", rec.Code)
	}
	// Headteacher may record for any class.
	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-OTHER/scores/STU-007", `{"score":5}`, head); rec.Code != http.StatusOK {
		t.Errorf("head any class: %d %s", rec.Code, rec.Body.String())
	}
	// Students and parents cannot write scores at all (route role gate).
	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-OWN/scores/STU-001", `{"score":1}`, student); rec.Code != http.StatusForbidden {
		t.Errorf("student: got %d want 403", rec.Code)
	}
	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-OWN/scores/STU-001", `{"score":1}`, parent); rec.Code != http.StatusForbidden {
		t.Errorf("parent: got %d want 403", rec.Code)
	}
}

func TestBulkScoresIdempotentReplay(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-BULK", "2026-10-01")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// One row by studentId, one by admissionNo.
	body := `[{"studentId":"STU-001","score":15},{"admissionNo":"S-2023-002","score":10}]`
	for i := 0; i < 2; i++ {
		rec := do(r, "POST", "/api/assessments/ASSMT-SO-BULK/scores/bulk", body, teacher)
		if rec.Code != http.StatusOK {
			t.Fatalf("replay %d: %d %s", i, rec.Code, rec.Body.String())
		}
		var resp struct {
			Saved   bool              `json:"saved"`
			Results []bulkScoreResult `json:"results"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &resp)
		if !resp.Saved || len(resp.Results) != 2 {
			t.Fatalf("replay %d: resp %+v", i, resp)
		}
	}
	// Replaying the same batch must not create a second row for either pupil.
	count := 0
	for _, s := range st.Submissions() {
		if s.AssessmentID == "ASSMT-SO-BULK" {
			count++
		}
	}
	if count != 2 {
		t.Errorf("rows after replay = %d, want 2 (idempotent)", count)
	}
	if s1, _ := st.SubmissionFor("ASSMT-SO-BULK", "STU-001"); s1.Earned != 15 {
		t.Errorf("STU-001 earned = %v, want 15", s1.Earned)
	}
	if s2, _ := st.SubmissionFor("ASSMT-SO-BULK", "STU-002"); s2.Earned != 10 {
		t.Errorf("STU-002 earned = %v, want 10 (matched on admissionNo)", s2.Earned)
	}
}

func TestBulkScoresAllOrNothing(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-ATOMIC", "2026-10-01")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// First row valid, second over the max: nothing may be written.
	body := `[{"studentId":"STU-001","score":15},{"studentId":"STU-002","score":999}]`
	rec := do(r, "POST", "/api/assessments/ASSMT-SO-ATOMIC/scores/bulk", body, teacher)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("got %d want 422 (%s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Saved   bool              `json:"saved"`
		Results []bulkScoreResult `json:"results"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp.Saved || resp.Results[0].Status != "ok" || resp.Results[1].Status != "error" {
		t.Errorf("results = %+v, want row0 ok / row1 error / not saved", resp)
	}
	if _, ok := st.SubmissionFor("ASSMT-SO-ATOMIC", "STU-001"); ok {
		t.Error("a valid row was written despite a sibling error — not atomic")
	}
}

func TestBulkScoresMatchingRules(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-MATCH", "2026-10-01")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// Unknown admissionNo, a duplicate student row, and a pupil from another
	// class are each rejected; no match is ever made on name.
	body := `[
		{"admissionNo":"S-9999-999","score":5},
		{"studentId":"STU-001","score":5},
		{"studentId":"STU-001","score":6},
		{"studentId":"STU-007","score":5}
	]`
	rec := do(r, "POST", "/api/assessments/ASSMT-SO-MATCH/scores/bulk", body, teacher)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("got %d want 422 (%s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Results []bulkScoreResult `json:"results"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp.Results[0].Status != "error" || resp.Results[2].Status != "error" || resp.Results[3].Status != "error" {
		t.Errorf("expected unknown/duplicate/other-class rows to error: %+v", resp.Results)
	}
}

func TestAbsentExcludedFromAverage(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-ABS", "2026-10-01")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-ABS/scores/STU-001", `{"absent":true}`, teacher); rec.Code != http.StatusOK {
		t.Fatalf("absent: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-ABS/scores/STU-002", `{"score":10}`, teacher); rec.Code != http.StatusOK {
		t.Fatalf("score: %d %s", rec.Code, rec.Body.String())
	}
	rec := do(r, "GET", "/api/assessments/ASSMT-SO-ABS/results", "", teacher)
	var results struct {
		Average float64 `json:"average"`
		Graded  int     `json:"graded"`
		Rows    []struct {
			Student domain.Student `json:"student"`
			Absent  bool           `json:"absent"`
			Percent float64        `json:"percent"`
		} `json:"rows"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &results)
	// Only STU-002 (10/20 = 50%) is graded; the absent pupil is excluded.
	if results.Graded != 1 || results.Average != 50 {
		t.Errorf("average = %v over %d graded, want 50 over 1", results.Average, results.Graded)
	}
	var sawAbsent bool
	for _, row := range results.Rows {
		if row.Student.ID == "STU-001" {
			sawAbsent = row.Absent
		}
	}
	if !sawAbsent {
		t.Error("absent pupil should still appear in the roster, flagged absent")
	}
}

func TestManualModeBlocksAIMarkingRoutes(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	setMarkingMode(t, st, domain.MarkingModeManual)
	scoreOnly(t, st, "ASSMT-SO-MM", "2026-10-01")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// AI capture and the marking-draft queue are both closed.
	if rec := do(r, "GET", "/api/questions/ai/requests", "", teacher); rec.Code != http.StatusForbidden {
		t.Errorf("ai requests in manual mode: got %d want 403", rec.Code)
	}
	if rec := do(r, "POST", "/api/questions/ai/requests", `{}`, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("ai request create in manual mode: got %d want 403", rec.Code)
	}
	if rec := do(r, "GET", "/api/marking-drafts", "", teacher); rec.Code != http.StatusForbidden {
		t.Errorf("marking drafts in manual mode: got %d want 403", rec.Code)
	}
	// Manual score entry still works in manual mode.
	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-MM/scores/STU-001", `{"score":5}`, teacher); rec.Code != http.StatusOK {
		t.Errorf("manual score in manual mode: got %d %s", rec.Code, rec.Body.String())
	}
}

func TestAIModeBlocksManualScores(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	setMarkingMode(t, st, domain.MarkingModeAI)
	scoreOnly(t, st, "ASSMT-SO-AI", "2026-10-01")
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-AI/scores/STU-001", `{"score":5}`, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("manual score in ai mode: got %d want 403", rec.Code)
	}
	if rec := do(r, "POST", "/api/assessments/ASSMT-SO-AI/scores/bulk", `[{"studentId":"STU-001","score":5}]`, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("bulk scores in ai mode: got %d want 403", rec.Code)
	}
}

func TestManualOverrideOfAIMarkedScore(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-OVR", "2026-10-01")
	// An AI-sourced score already exists for STU-001.
	if err := st.SaveSubmission(domain.Submission{ID: "SUB-AI-1", AssessmentID: "ASSMT-SO-OVR",
		StudentID: "STU-001", ClassID: "JHS2A", Earned: 8, Source: domain.SourceAI,
		Answers: map[string]string{}, TeacherMarks: map[string]float64{}}); err != nil {
		t.Fatal(err)
	}
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// Without override the edit is refused and the AI score is untouched.
	rec := do(r, "PUT", "/api/assessments/ASSMT-SO-OVR/scores/STU-001", `{"score":12}`, teacher)
	if rec.Code != http.StatusConflict {
		t.Fatalf("no override: got %d want 409 (%s)", rec.Code, rec.Body.String())
	}
	if sub, _ := st.SubmissionFor("ASSMT-SO-OVR", "STU-001"); sub.Earned != 8 || sub.Source != domain.SourceAI {
		t.Errorf("AI score changed without override: %+v", sub)
	}
	// With override the manual score replaces it and the edit is audited.
	rec = do(r, "PUT", "/api/assessments/ASSMT-SO-OVR/scores/STU-001", `{"score":12,"override":true}`, teacher)
	if rec.Code != http.StatusOK {
		t.Fatalf("override: got %d %s", rec.Code, rec.Body.String())
	}
	if sub, _ := st.SubmissionFor("ASSMT-SO-OVR", "STU-001"); sub.Earned != 12 || sub.Source != domain.SourceManual {
		t.Errorf("after override = %+v, want 12/manual", sub)
	}
	var audited bool
	for _, e := range st.AuditLogs() {
		if e.Action == "score.manual" && e.Reason == "override of AI-marked score" {
			audited = true
		}
	}
	if !audited {
		t.Error("an AI-score override must be audited with its reason")
	}
}

func TestFinishedTermLocksScores(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	scoreOnly(t, st, "ASSMT-SO-FIN", "2026-10-01")
	if err := st.SaveFinishedTerm("SCH-001", domain.FinishedTerm{
		SchoolTerm: domain.SchoolTerm{Year: "2026/2027", Name: "Term 1",
			Start: "2026-09-01", End: "2026-12-20"},
	}); err != nil {
		t.Fatal(err)
	}
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))
	if rec := do(r, "PUT", "/api/assessments/ASSMT-SO-FIN/scores/STU-001", `{"score":5}`, teacher); rec.Code != http.StatusConflict {
		t.Errorf("finished term: got %d want 409 (%s)", rec.Code, rec.Body.String())
	}
}

func TestScoreOnlyAssessmentCreateAndResults(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	// A teacher creates a score-only class test — title/type/subject/class/date
	// and a max score, no questions.
	body := `{"title":"Paper Quiz","type":"classTest","subjectId":"MATH","classId":"JHS2A","date":"2026-10-02","maxScore":50}`
	rec := do(r, "POST", "/api/assessments", body, teacher)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create score-only: %d %s", rec.Code, rec.Body.String())
	}
	var created domain.Assessment
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if created.MaxScore == nil || *created.MaxScore != 50 || len(created.Questions) != 0 {
		t.Fatalf("created = %+v, want maxScore 50 and no questions", created)
	}
	if created.EffectiveTotal() != 50 {
		t.Errorf("effective total = %v, want 50", created.EffectiveTotal())
	}

	// A max score of 0 is rejected.
	bad := `{"title":"Bad","type":"classTest","subjectId":"MATH","classId":"JHS2A","maxScore":0}`
	if rec := do(r, "POST", "/api/assessments", bad, teacher); rec.Code != http.StatusBadRequest {
		t.Errorf("maxScore 0: got %d want 400", rec.Code)
	}

	// Record a score and confirm results are out of 50.
	do(r, "PUT", "/api/assessments/"+created.ID+"/scores/STU-001", `{"score":25}`, teacher)
	rec = do(r, "GET", "/api/assessments/"+created.ID+"/results", "", teacher)
	var results struct {
		TotalMarks float64 `json:"totalMarks"`
		Rows       []struct {
			Student domain.Student `json:"student"`
			Percent float64        `json:"percent"`
		} `json:"rows"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &results)
	if results.TotalMarks != 50 {
		t.Errorf("results total = %v, want 50", results.TotalMarks)
	}
	for _, row := range results.Rows {
		if row.Student.ID == "STU-001" && row.Percent != 50 {
			t.Errorf("STU-001 percent = %v, want 50 (25/50)", row.Percent)
		}
	}
}
