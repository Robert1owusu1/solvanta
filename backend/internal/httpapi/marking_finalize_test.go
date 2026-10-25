package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"solvanta/backend/internal/domain"
)

// =============================================================================
// Finalizing a reviewed draft — Phase 6
// =============================================================================

// matchingSchemeFixture mirrors ASSMT-MAT-HALF question for question:
// Q-MATH-001 (MCQ, 2), Q-MATH-002 (MCQ, 3), Q-MATH-003 (worked, 4).
const matchingSchemeFixture = `[
  {"questionNumber":1,"totalMarks":2,
   "markBreakdown":[{"type":"final_answer","criteria":"Equivalent fraction","marks":2}],
   "acceptedAnswers":[{"answerText":"2/4","normalizedForm":"24","marksAwarded":2,"isPrimary":true}],
   "misconceptions":[]},
  {"questionNumber":2,"totalMarks":3,
   "markBreakdown":[{"type":"method","criteria":"Multiply","marks":1},{"type":"final_answer","criteria":"Length","marks":2}],
   "acceptedAnswers":[{"answerText":"3/8 m","normalizedForm":"38m","marksAwarded":3,"isPrimary":true}],
   "misconceptions":[]},
  {"questionNumber":3,"totalMarks":4,
   "markBreakdown":[{"type":"method","criteria":"Common denominator","marks":2},{"type":"final_answer","criteria":"Simplified","marks":2}],
   "acceptedAnswers":[{"answerText":"11/12","normalizedForm":"1112","marksAwarded":4,"isPrimary":true}],
   "misconceptions":[]}
]`

// draftForSTU002 creates the matching scheme (as the headteacher — a
// diagnostic is an exam type) and a teacher's draft of SUB-M1-STU002:
// Q1 right (2), Q2 "1/2 m" not in the scheme (0, flagged), Q3 right (4).
func draftForSTU002(t *testing.T, r http.Handler, teacher, head string) (domain.MarkingScheme, draftReply) {
	t.Helper()
	rec := do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/marking-scheme",
		`{"assessmentId":"ASSMT-MAT-HALF","questions":`+matchingSchemeFixture+`}`, bearer(head))
	if rec.Code != http.StatusCreated {
		t.Fatalf("scheme: %d %s", rec.Code, rec.Body.String())
	}
	var scheme domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &scheme)
	code, d, body := postDraft(t, r, teacher, typedDraft(scheme.ID,
		`[{"questionNumber":1,"text":"2/4"},{"questionNumber":2,"text":"1/2 m","working":["3/4 x 1/2"]},{"questionNumber":3,"text":"11/12"}]`))
	if code != http.StatusCreated {
		t.Fatalf("draft: %d %s", code, body)
	}
	return scheme, d
}

func finalizeBody(d draftReply, marks map[int]float64, notes map[int]string) string {
	var parts []string
	for _, a := range d.Answers {
		m, ok := marks[a.QuestionNumber]
		if !ok {
			continue
		}
		parts = append(parts, fmt.Sprintf(`{"schemeQuestionId":%q,"marks":%v,"note":%q}`,
			a.SchemeQuestionID, m, notes[a.QuestionNumber]))
	}
	return `{"marks":[` + strings.Join(parts, ",") + `]}`
}

func TestFinalizeRecordsTheTeachersMarks(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	scheme, d := draftForSTU002(t, r, teacher, head)
	if d.DraftTotal != 6 || d.Final {
		t.Fatalf("draft = %v (final %v), want 6 and not final", d.DraftTotal, d.Final)
	}

	// The teacher accepts Q1 and Q3 and gives Q2 one method mark.
	rec := do(r, "POST", "/api/marking-drafts/"+d.ID+"/finalize",
		finalizeBody(d, map[int]float64{1: 2, 2: 1, 3: 4}, map[int]string{2: "Correct method, wrong final step"}),
		bearer(teacher))
	if rec.Code != http.StatusOK {
		t.Fatalf("finalize: %d %s", rec.Code, rec.Body.String())
	}
	var done draftReply
	_ = json.Unmarshal(rec.Body.Bytes(), &done)
	var finalTotal struct {
		FinalTotal float64 `json:"finalTotal"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &finalTotal)
	if !done.Final || done.Status != domain.DraftStatusFinalized || finalTotal.FinalTotal != 7 || done.FinalizedBy == "" {
		t.Fatalf("finalized draft: %+v total %v", done, finalTotal.FinalTotal)
	}
	q2 := done.Answers[1]
	if q2.DraftMarks != 0 || q2.FinalMarks == nil || *q2.FinalMarks != 1 || q2.TeacherNote == "" {
		t.Errorf("the proposal and the decision must both be kept: %+v", q2)
	}

	// The recorded score is exactly what the teacher finalized, every
	// question included (an MCQ mark wins over the auto-mark).
	sub, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-002")
	if sub.Earned != 7 || sub.TeacherMarks["Q-MATH-001"] != 2 || sub.TeacherMarks["Q-MATH-002"] != 1 ||
		sub.TeacherMarks["Q-MATH-003"] != 4 || sub.MarkingSchemeID != scheme.ID {
		t.Errorf("recorded submission: %+v", sub)
	}
	found := false
	for _, n := range st.Notifications() {
		if n.StudentID == "STU-002" && strings.Contains(n.Body, "7/9") {
			found = true
		}
	}
	if !found {
		t.Error("no parent notification with the finalized 7/9")
	}

	// Done means done: no second finalize, and no redraft over it.
	if rec := do(r, "POST", "/api/marking-drafts/"+d.ID+"/finalize",
		finalizeBody(d, map[int]float64{1: 2, 2: 3, 3: 4}, nil), bearer(teacher)); rec.Code != http.StatusConflict {
		t.Errorf("second finalize: got %d, want 409", rec.Code)
	}
	if code, _, _ := postDraft(t, r, teacher, typedDraft(scheme.ID, `[{"questionNumber":1,"text":"2/4"}]`)); code != http.StatusConflict {
		t.Errorf("redraft of a finalized paper: got %d, want 409", code)
	}
}

func TestFinalizeNeedsAnExplicitMarkForEveryQuestion(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	_, d := draftForSTU002(t, r, teacher, head)
	before, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-002")

	cases := []struct {
		name string
		body string
	}{
		{"nothing", `{"marks":[]}`},
		{"a question missing", finalizeBody(d, map[int]float64{1: 2, 3: 4}, nil)},
		{"above the total", finalizeBody(d, map[int]float64{1: 2, 2: 9, 3: 4}, nil)},
		{"negative", finalizeBody(d, map[int]float64{1: 2, 2: -1, 3: 4}, nil)},
		{"three decimals", finalizeBody(d, map[int]float64{1: 2, 2: 1.333, 3: 4}, nil)},
	}
	for _, tc := range cases {
		if rec := do(r, "POST", "/api/marking-drafts/"+d.ID+"/finalize", tc.body, bearer(teacher)); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400 (%s)", tc.name, rec.Code, rec.Body.String())
		}
	}
	after, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-002")
	if after.Earned != before.Earned || len(after.TeacherMarks) != len(before.TeacherMarks) {
		t.Errorf("a refused finalize changed the recorded marks: %+v", after)
	}
	if got, _ := st.MarkingDraftByID(d.ID); got.Status != domain.DraftStatusDraft {
		t.Errorf("a refused finalize changed the draft: %s", got.Status)
	}

	// Students, parents and staff cannot finalize.
	for _, who := range [][2]string{{"kojo.owusu@school.gh", "student123"}, {"ama.owusu@school.gh", "parent123"}, {"staff@school.gh", "staff123"}} {
		body := finalizeBody(d, map[int]float64{1: 2, 2: 3, 3: 4}, nil)
		if rec := do(r, "POST", "/api/marking-drafts/"+d.ID+"/finalize", body, bearer(login(t, r, who[0], who[1]))); rec.Code != http.StatusForbidden {
			t.Errorf("%s: got %d, want 403", who[0], rec.Code)
		}
	}
}

// TestFinalizeRefusesASchemeThatDoesNotFitTheAssessment: when scheme question
// n is not the assessment's question n with the same marks, the recorded
// score could not equal what the teacher finalized, so nothing is written.
func TestFinalizeRefusesASchemeThatDoesNotFitTheAssessment(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	scheme := createScheme(t, r, head, "ASSMT-MAT-HALF") // 2 questions, 4 + 3 marks
	_, d, _ := postDraft(t, r, teacher, typedDraft(scheme.ID, `[{"questionNumber":1,"text":"2/4"},{"questionNumber":2,"text":"11/12"}]`))
	rec := do(r, "POST", "/api/marking-drafts/"+d.ID+"/finalize", finalizeBody(d, map[int]float64{1: 4, 2: 3}, nil), bearer(teacher))
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "cannot be recorded") {
		t.Fatalf("mismatched scheme: %d %s", rec.Code, rec.Body.String())
	}
	if got, _ := st.MarkingDraftByID(d.ID); got.Status != domain.DraftStatusDraft {
		t.Errorf("draft finalized despite the refusal: %s", got.Status)
	}
}

func TestReviewQueue(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	_, d := draftForSTU002(t, r, teacher, head)

	queue := func(tok, status string) []draftReply {
		rec := do(r, "GET", "/api/marking-drafts?status="+status, "", bearer(tok))
		if rec.Code != http.StatusOK {
			t.Fatalf("queue: %d %s", rec.Code, rec.Body.String())
		}
		var out []draftReply
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return out
	}
	if q := queue(teacher, "draft"); len(q) != 1 || q[0].ID != d.ID || q[0].NeedsReview != 1 {
		t.Fatalf("teacher's queue: %+v", q)
	}
	if rec := do(r, "GET", "/api/marking-drafts", "", bearer(teacher)); rec.Code != http.StatusBadRequest {
		t.Errorf("no filter: got %d, want 400", rec.Code)
	}
	do(r, "POST", "/api/marking-drafts/"+d.ID+"/finalize", finalizeBody(d, map[int]float64{1: 2, 2: 0, 3: 4}, nil), bearer(teacher))
	if q := queue(teacher, "draft"); len(q) != 0 {
		t.Errorf("finalized draft still queued: %+v", q)
	}
	if q := queue(head, "finalized"); len(q) != 1 {
		t.Errorf("finalized list for the head: %+v", q)
	}
}

func TestFinalizeAnAssignmentDraft(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	rec := do(r, "POST", "/api/assignments/ASG-001/marking-scheme",
		`{"assignmentId":"ASG-001","questions":`+schemeQuestionsFixture+`}`, bearer(teacher))
	var scheme domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &scheme)
	do(r, "PUT", "/api/records/assignment_submissions/ASUB-F",
		`{"id":"ASUB-F","assignmentId":"ASG-001","studentId":"STU-002","classId":"JHS2A","pages":[]}`, bearer(teacher))
	_, d, body := postDraft(t, r, teacher, fmt.Sprintf(
		`{"schemeId":%q,"submissionId":"ASUB-F","studentId":"STU-002","answers":[{"questionNumber":1,"text":"2/4"},{"questionNumber":2,"text":"11/12"}]}`, scheme.ID))
	if d.ID == "" {
		t.Fatalf("draft: %s", body)
	}
	rec = do(r, "POST", "/api/marking-drafts/"+d.ID+"/finalize", finalizeBody(d, map[int]float64{1: 4, 2: 3}, nil), bearer(teacher))
	var done draftReply
	_ = json.Unmarshal(rec.Body.Bytes(), &done)
	if rec.Code != http.StatusOK || !done.Final {
		t.Fatalf("assignment finalize: %d %s", rec.Code, rec.Body.String())
	}
}

// TestDraftFindsTheAssessmentPaperByStudent: the app's local id for a
// captured paper is not the server's, so an assessment draft may name only
// the student; the server records the paper's real id.
func TestDraftFindsTheAssessmentPaperByStudent(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	scheme := createScheme(t, r, login(t, r, "head@school.gh", "head123"), "ASSMT-MAT-HALF")
	code, d, body := postDraft(t, r, teacher, fmt.Sprintf(
		`{"schemeId":%q,"studentId":"STU-002","answers":[{"questionNumber":1,"text":"2/4"}]}`, scheme.ID))
	if code != http.StatusCreated || d.SubmissionID != "SUB-M1-STU002" {
		t.Fatalf("draft by student: %d %s", code, body)
	}
	// An assignment still needs the paper named.
	rec := do(r, "POST", "/api/assignments/ASG-001/marking-scheme",
		`{"assignmentId":"ASG-001","questions":`+schemeQuestionsFixture+`}`, bearer(teacher))
	var asg domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &asg)
	if code, _, _ := postDraft(t, r, teacher, fmt.Sprintf(
		`{"schemeId":%q,"studentId":"STU-002","answers":[{"questionNumber":1,"text":"2/4"}]}`, asg.ID)); code != http.StatusNotFound {
		t.Errorf("assignment without submissionId: got %d, want 404", code)
	}
}
