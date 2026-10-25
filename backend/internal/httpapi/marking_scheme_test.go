package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// =============================================================================
// Marking scheme persistence + versioning — Phase 2 guards
// =============================================================================

// newTestServerWithStore returns the router together with the backing store so
// a test can seed submissions directly. The HTTP surface deliberately exposes
// no "create submission" endpoint (submissions arrive via /:id/submit), and
// nothing there links a submission to a marking scheme — but
// SubmissionsByScheme is the predicate the whole versioning rule hangs off, so
// tests must be able to arrange that state.
func newTestServerWithStore(t *testing.T, cfg Config) (*gin.Engine, *store.Memory) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	st := store.New()
	s, err := NewServer(st, cfg)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return s.Router(), st
}

// schemeQuestionsFixture is a 2-question payload where every question carries
// accepted answers and at least one misconception, exercising all three levels
// of the schema (question → answer/misconception back-references).
//
// Satisfies the handler's validation: question numbers sequential from 1,
// positive total marks, breakdown sums equal to the total, and exactly one
// primary accepted answer per question.
const schemeQuestionsFixture = `[
  {
    "id": "SQ-1",
    "schemeId": "",
    "questionNumber": 1,
    "totalMarks": 4,
    "markBreakdown": [
      {"id": "step-1", "type": "method", "criteria": "Convert to a common denominator", "marks": 2},
      {"id": "step-2", "type": "final_answer", "criteria": "Simplify correctly", "marks": 2}
    ],
    "acceptedAnswers": [
      {"id": 1, "schemeQuestionId": "", "answerText": "2/4", "normalizedForm": "24", "marksAwarded": 4, "isPrimary": true, "createdAt": ""},
      {"id": 2, "schemeQuestionId": "", "answerText": "1/2", "normalizedForm": "12", "marksAwarded": 3, "isPrimary": false, "createdAt": ""}
    ],
    "misconceptions": [
      {"id": 101, "schemeQuestionId": "", "wrongAnswerPattern": "34", "likelyCause": "Did not invert the divisor when dividing", "marksAwarded": 1, "createdAt": ""}
    ],
    "createdAt": ""
  },
  {
    "id": "SQ-2",
    "schemeId": "",
    "questionNumber": 2,
    "totalMarks": 3,
    "markBreakdown": [
      {"id": "step-1", "type": "final_answer", "criteria": "Correct fraction of the whole", "marks": 3}
    ],
    "acceptedAnswers": [
      {"id": 3, "schemeQuestionId": "", "answerText": "11/12", "normalizedForm": "1112", "marksAwarded": 3, "isPrimary": true, "createdAt": ""}
    ],
    "misconceptions": [
      {"id": 102, "schemeQuestionId": "", "wrongAnswerPattern": "13", "likelyCause": "Added instead of finding a common denominator", "marksAwarded": 1, "createdAt": ""}
    ],
    "createdAt": ""
  }
]`

// createScheme posts the fixture and returns the created scheme, failing the
// test on any non-201.
func createScheme(t *testing.T, r http.Handler, token, assessmentID string) domain.MarkingScheme {
	t.Helper()
	body := fmt.Sprintf(`{"assessmentId":%q,"questions":%s}`, assessmentID, schemeQuestionsFixture)
	rec := do(r, "POST", "/api/assessments/"+assessmentID+"/marking-scheme", body,
		map[string]string{"Authorization": "Bearer " + token})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create scheme: got %d %s", rec.Code, rec.Body.String())
	}
	var created domain.MarkingScheme
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("unmarshal created scheme: %v", err)
	}
	return created
}

// getScheme fetches a scheme back through getMarkingScheme — the read path a
// reload of the editor actually takes.
func getScheme(t *testing.T, r http.Handler, token, id string) domain.MarkingScheme {
	t.Helper()
	rec := do(r, "GET", "/api/marking-schemes/"+id, "",
		map[string]string{"Authorization": "Bearer " + token})
	if rec.Code != http.StatusOK {
		t.Fatalf("get scheme %s: got %d %s", id, rec.Code, rec.Body.String())
	}
	var got domain.MarkingScheme
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal scheme: %v", err)
	}
	return got
}

// TestSchemeQuestionsLinkToSchemeOnReload is the regression guard for the
// "questions saved with an empty scheme_id and vanish on reload" bug.
//
// It creates a scheme with 2 questions (each with accepted answers and a
// misconception), reads it back through getMarkingScheme, and asserts every
// row came back with the correct parent link.
func TestSchemeQuestionsLinkToSchemeOnReload(t *testing.T) {
	r := newTestServer(t, Config{})
	token := login(t, r, demoAccounts["schoolAdmin"][0], demoAccounts["schoolAdmin"][1])

	created := createScheme(t, r, token, "ASSMT-MAT-HALF")
	if created.ID == "" {
		t.Fatal("created scheme has empty id")
	}
	if len(created.Questions) != 2 {
		t.Fatalf("create response: got %d questions, want 2", len(created.Questions))
	}

	got := getScheme(t, r, token, created.ID)

	if got.ID != created.ID {
		t.Fatalf("reloaded id = %q, want %q", got.ID, created.ID)
	}
	if len(got.Questions) != 2 {
		t.Fatalf("reloaded %d questions, want 2 — questions did not link to scheme_id",
			len(got.Questions))
	}

	wantAnswers := map[int]int{1: 2, 2: 1}
	wantMisconceptions := map[int]int{1: 1, 2: 1}

	for _, q := range got.Questions {
		// Level 1: question → scheme.
		if q.SchemeID != got.ID {
			t.Errorf("question %d: scheme_id = %q, want %q",
				q.QuestionNumber, q.SchemeID, got.ID)
		}
		if q.ID == "" {
			t.Errorf("question %d: empty id", q.QuestionNumber)
		}

		// Level 2: accepted answers → question.
		if n := len(q.AcceptedAnswers); n != wantAnswers[q.QuestionNumber] {
			t.Errorf("question %d: got %d accepted answers, want %d",
				q.QuestionNumber, n, wantAnswers[q.QuestionNumber])
		}
		for _, aa := range q.AcceptedAnswers {
			if aa.SchemeQuestionID != q.ID {
				t.Errorf("question %d answer %d: scheme_question_id = %q, want %q",
					q.QuestionNumber, aa.ID, aa.SchemeQuestionID, q.ID)
			}
		}

		// Level 3: misconceptions → question.
		if n := len(q.Misconceptions); n != wantMisconceptions[q.QuestionNumber] {
			t.Errorf("question %d: got %d misconceptions, want %d",
				q.QuestionNumber, n, wantMisconceptions[q.QuestionNumber])
		}
		for _, m := range q.Misconceptions {
			if m.SchemeQuestionID != q.ID {
				t.Errorf("question %d misconception %d: scheme_question_id = %q, want %q",
					q.QuestionNumber, m.ID, m.SchemeQuestionID, q.ID)
			}
		}
	}

	// The data itself must survive the round-trip, not just the ids.
	q1 := got.Questions[0]
	if q1.TotalMarks != 4 {
		t.Errorf("question 1 totalMarks = %v, want 4", q1.TotalMarks)
	}
	if len(q1.MarkBreakdown) != 2 {
		t.Errorf("question 1 has %d breakdown steps, want 2", len(q1.MarkBreakdown))
	}
	if q1.AcceptedAnswers[0].AnswerText != "2/4" {
		t.Errorf("question 1 primary answer = %q, want %q",
			q1.AcceptedAnswers[0].AnswerText, "2/4")
	}
	if !q1.AcceptedAnswers[0].IsPrimary {
		t.Error("question 1: first accepted answer lost its primary flag")
	}
	if q1.Misconceptions[0].WrongAnswerPattern != "34" {
		t.Errorf("question 1 misconception pattern = %q, want %q",
			q1.Misconceptions[0].WrongAnswerPattern, "34")
	}

	// The per-assessment list (what the editor loads on open) must agree.
	rec := do(r, "GET", "/api/assessments/ASSMT-MAT-HALF/marking-scheme", "",
		map[string]string{"Authorization": "Bearer " + token})
	if rec.Code != http.StatusOK {
		t.Fatalf("list schemes: got %d %s", rec.Code, rec.Body.String())
	}
	var list []domain.MarkingScheme
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("unmarshal scheme list: %v", err)
	}
	if len(list) == 0 {
		t.Fatal("per-assessment scheme list is empty")
	}
	if len(list[0].Questions) != 2 {
		t.Errorf("list[0] has %d questions, want 2", len(list[0].Questions))
	}
}

// TestNotesOnlyEditUpdatesInPlaceWithSubmissions pins the rule that a teacher
// editing only a misconception note — no answer, no mark, no breakdown — must
// NOT fork a new version, even while submissions exist against the scheme,
// because the edit cannot affect any grade already recorded. The note itself
// must still be persisted.
func TestNotesOnlyEditUpdatesInPlaceWithSubmissions(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	token := login(t, r, demoAccounts["schoolAdmin"][0], demoAccounts["schoolAdmin"][1])

	created := createScheme(t, r, token, "ASSMT-MAT-HALF")

	// Arrange the state that makes versioning relevant: submissions marked
	// against this exact scheme.
	if err := st.SaveSubmission(domain.Submission{
		ID:                   "SUB-SCHEME-001",
		AssessmentID:         "ASSMT-MAT-HALF",
		StudentID:            "STU-001",
		ClassID:              "JHS2A",
		Date:                 "2026-09-10",
		MarkingSchemeID:      created.ID,
		MarkingSchemeVersion: created.Version,
	}); err != nil {
		t.Fatalf("seed submission: %v", err)
	}
	if n := len(st.SubmissionsByScheme(created.ID)); n != 1 {
		t.Fatalf("expected 1 submission against scheme, got %d", n)
	}

	// Read the scheme back, then change ONLY a misconception note.
	existing := getScheme(t, r, token, created.ID)
	existing.Questions[0].Misconceptions[0].LikelyCause =
		"Reworded for clarity in feedback to students."

	payload, err := json.Marshal(map[string]any{"questions": existing.Questions})
	if err != nil {
		t.Fatalf("marshal update: %v", err)
	}
	rec := do(r, "PUT", "/api/marking-schemes/"+created.ID, string(payload),
		map[string]string{"Authorization": "Bearer " + token})
	if rec.Code != http.StatusOK {
		t.Fatalf("notes-only update: got %d %s", rec.Code, rec.Body.String())
	}

	var updated domain.MarkingScheme
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatalf("unmarshal updated: %v", err)
	}

	// Must stay on the SAME row and SAME version.
	if updated.ID != created.ID {
		t.Errorf("notes-only edit created a new scheme: id %q → %q, want in-place %q",
			created.ID, updated.ID, created.ID)
	}
	if updated.Version != created.Version {
		t.Errorf("notes-only edit bumped version %d → %d, want to stay %d",
			created.Version, updated.Version, created.Version)
	}
	if updated.ParentSchemeID != "" {
		t.Errorf("notes-only edit set parent_scheme_id = %q, want empty",
			updated.ParentSchemeID)
	}

	// And no second scheme row may have appeared for this assessment.
	schemes := st.MarkingSchemesByAssessment("ASSMT-MAT-HALF")
	if len(schemes) != 1 {
		t.Errorf("got %d schemes for assessment, want 1 (in-place update must not fork)",
			len(schemes))
	}

	// The note must actually be persisted — an update that silently drops the
	// teacher's edit would be just as wrong as one that forks a version.
	reloaded := getScheme(t, r, token, created.ID)
	const wantNote = "Reworded for clarity in feedback to students."
	if got := reloaded.Questions[0].Misconceptions[0].LikelyCause; got != wantNote {
		t.Errorf("note not persisted: got %q, want %q", got, wantNote)
	}
	// The grade-relevant fields around it must be untouched.
	if len(reloaded.Questions) != 2 {
		t.Errorf("reloaded %d questions, want 2", len(reloaded.Questions))
	}
	if reloaded.Questions[0].Misconceptions[0].WrongAnswerPattern != "34" {
		t.Errorf("misconception pattern changed to %q, want %q",
			reloaded.Questions[0].Misconceptions[0].WrongAnswerPattern, "34")
	}
}

// TestGradeRelevantEditCreatesNewVersionWithSubmissions is the counterpart
// guard: once the notes-only exemption is in place, a real change (a mark
// value) must still fork a new version while submissions exist. Without this,
// over-relaxing the change detector would silently re-grade history.
func TestGradeRelevantEditCreatesNewVersionWithSubmissions(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	token := login(t, r, demoAccounts["schoolAdmin"][0], demoAccounts["schoolAdmin"][1])

	created := createScheme(t, r, token, "ASSMT-MAT-HALF")

	if err := st.SaveSubmission(domain.Submission{
		ID:                   "SUB-SCHEME-002",
		AssessmentID:         "ASSMT-MAT-HALF",
		StudentID:            "STU-001",
		ClassID:              "JHS2A",
		Date:                 "2026-09-10",
		MarkingSchemeID:      created.ID,
		MarkingSchemeVersion: created.Version,
	}); err != nil {
		t.Fatalf("seed submission: %v", err)
	}

	existing := getScheme(t, r, token, created.ID)
	// Change a grade-relevant value: the partial marks a misconception awards.
	existing.Questions[0].Misconceptions[0].MarksAwarded = 2

	payload, err := json.Marshal(map[string]any{"questions": existing.Questions})
	if err != nil {
		t.Fatalf("marshal update: %v", err)
	}
	rec := do(r, "PUT", "/api/marking-schemes/"+created.ID, string(payload),
		map[string]string{"Authorization": "Bearer " + token})
	if rec.Code != http.StatusOK {
		t.Fatalf("grade-relevant update: got %d %s", rec.Code, rec.Body.String())
	}

	var updated domain.MarkingScheme
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatalf("unmarshal updated: %v", err)
	}

	if updated.ID == created.ID {
		t.Error("grade-relevant edit reused the existing scheme id; want a new version row")
	}
	if updated.Version != created.Version+1 {
		t.Errorf("version = %d, want %d", updated.Version, created.Version+1)
	}
	if updated.ParentSchemeID != created.ID {
		t.Errorf("parent_scheme_id = %q, want %q (chain must link one step back)",
			updated.ParentSchemeID, created.ID)
	}

	// The original version must remain intact for the submission recorded
	// against it.
	original := getScheme(t, r, token, created.ID)
	if original.Questions[0].Misconceptions[0].MarksAwarded != 1 {
		t.Errorf("original v%d marksAwarded = %v, want 1 (must not be re-graded)",
			original.Version, original.Questions[0].Misconceptions[0].MarksAwarded)
	}
	if n := len(st.MarkingSchemesByAssessment("ASSMT-MAT-HALF")); n != 2 {
		t.Errorf("got %d schemes, want 2 (v1 preserved + v2 forked)", n)
	}
}

// TestUnchangedSchemeIsNoOp guards the early-return: an identical payload must
// not fork a version even when submissions exist.
func TestUnchangedSchemeIsNoOp(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	token := login(t, r, demoAccounts["schoolAdmin"][0], demoAccounts["schoolAdmin"][1])

	created := createScheme(t, r, token, "ASSMT-MAT-HALF")

	if err := st.SaveSubmission(domain.Submission{
		ID:                   "SUB-SCHEME-003",
		AssessmentID:         "ASSMT-MAT-HALF",
		StudentID:            "STU-001",
		ClassID:              "JHS2A",
		Date:                 "2026-09-10",
		MarkingSchemeID:      created.ID,
		MarkingSchemeVersion: created.Version,
	}); err != nil {
		t.Fatalf("seed submission: %v", err)
	}

	existing := getScheme(t, r, token, created.ID)
	payload, err := json.Marshal(map[string]any{"questions": existing.Questions})
	if err != nil {
		t.Fatalf("marshal update: %v", err)
	}
	rec := do(r, "PUT", "/api/marking-schemes/"+created.ID, string(payload),
		map[string]string{"Authorization": "Bearer " + token})
	if rec.Code != http.StatusOK {
		t.Fatalf("no-op update: got %d %s", rec.Code, rec.Body.String())
	}

	var updated domain.MarkingScheme
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatalf("unmarshal updated: %v", err)
	}
	if updated.ID != created.ID || updated.Version != created.Version {
		t.Errorf("identical payload changed scheme: %q v%d → %q v%d",
			created.ID, created.Version, updated.ID, updated.Version)
	}
	if n := len(st.MarkingSchemesByAssessment("ASSMT-MAT-HALF")); n != 1 {
		t.Errorf("got %d schemes, want 1", n)
	}
}
