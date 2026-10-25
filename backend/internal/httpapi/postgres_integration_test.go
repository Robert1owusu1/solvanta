package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// TestMarkingSchemeLifecycleOnPostgres drives the scheme API against a real
// database. The in-memory store has no unique or check constraints and kept
// fields Postgres dropped, so three defects passed every memory test: in-place
// edits hit UNIQUE (scheme_id, question_number), submissions lost their scheme
// link, and an edit after marking therefore rewrote graded work in place.
//
// Runs only when TEST_POSTGRES_DSN is set. Ids are minted fresh each run, so
// the seeded database is shared safely without truncating it.
func TestMarkingSchemeLifecycleOnPostgres(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN not set; skipping PostgreSQL integration test")
	}
	pg, err := store.NewPostgres(dsn, false)
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(func() { pg.Close() })
	store.Seed(pg)
	errsBefore, _, _ := pg.StoreErrors()

	gin.SetMode(gin.TestMode)
	s, err := NewServer(pg, Config{})
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	r := s.Router()
	tok := login(t, r, "head@school.gh", "head123")

	created := createScheme(t, r, tok, "ASSMT-MAT-HALF")
	answers := func(id string) int {
		n := 0
		for _, q := range pg.SchemeQuestions(id) {
			n += len(q.AcceptedAnswers)
		}
		return n
	}

	// 1. In-place edit with nothing marked yet.
	edited := strings.Replace(schemeQuestionsFixture, `"answerText": "1/2"`, `"answerText": "0.5"`, 1)
	rec := do(r, "PUT", "/api/marking-schemes/"+created.ID, fmt.Sprintf(`{"questions":%s}`, edited), bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("in-place edit: got %d %s", rec.Code, rec.Body.String())
	}
	if q := pg.SchemeQuestions(created.ID); len(q) != 2 || answers(created.ID) != 3 {
		t.Fatalf("after in-place edit: %d questions, %d answers; want 2 and 3", len(q), answers(created.ID))
	}

	// 2. Mark a submission against it; the link must survive a resubmission.
	student := fmt.Sprintf("STU-PG-%s", created.ID)
	sub := domain.Submission{ID: "SUB-" + created.ID, AssessmentID: "ASSMT-MAT-HALF", StudentID: student,
		ClassID: "JHS2A", Date: "2026-09-10", MarkingSchemeID: created.ID, MarkingSchemeVersion: created.Version}
	if err := pg.SaveStudent(domain.Student{ID: student, FirstName: "PG", LastName: "Test", ClassID: "JHS2A", SchoolID: "SCH-001"}); err != nil {
		t.Fatal(err)
	}
	if err := pg.SaveSubmission(sub); err != nil {
		t.Fatal(err)
	}
	sub.MarkingSchemeID, sub.MarkingSchemeVersion = "", 0
	if err := pg.SaveSubmission(sub); err != nil {
		t.Fatal(err)
	}
	if n := len(pg.SubmissionsByScheme(created.ID)); n != 1 {
		t.Fatalf("submissions against scheme = %d, want 1 (link lost on save)", n)
	}

	// 3. A grade-relevant edit now forks a new version and leaves v1 intact.
	regraded := strings.Replace(schemeQuestionsFixture, `"answerText": "11/12"`, `"answerText": "22/24"`, 1)
	rec = do(r, "PUT", "/api/marking-schemes/"+created.ID, fmt.Sprintf(`{"questions":%s}`, regraded), bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("versioned edit: got %d %s", rec.Code, rec.Body.String())
	}
	var v2 domain.MarkingScheme
	if err := json.Unmarshal(rec.Body.Bytes(), &v2); err != nil {
		t.Fatal(err)
	}
	if v2.ID == created.ID || v2.ParentSchemeID != created.ID || v2.Version != created.Version+1 {
		t.Fatalf("expected a new version linked to %s, got %+v", created.ID, v2)
	}
	if answers(created.ID) != 3 || answers(v2.ID) != 3 {
		t.Errorf("answers v1=%d v2=%d, want 3 each", answers(created.ID), answers(v2.ID))
	}

	if n, last, _ := pg.StoreErrors(); n != errsBefore {
		t.Errorf("%d storage error(s), last: %v", n-errsBefore, last)
	}
}

// TestMarksAreRecordedOnPostgres repeats the capture → verdict → results flow
// against PostgreSQL, where earned is NUMERIC(8,2) and teacher marks are
// JSONB: a half mark must come back as exactly what was given.
func TestMarksAreRecordedOnPostgres(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN not set; skipping PostgreSQL integration test")
	}
	pg, err := store.NewPostgres(dsn, false)
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(func() { pg.Close() })
	store.Seed(pg)
	errsBefore, _, _ := pg.StoreErrors()
	gin.SetMode(gin.TestMode)
	s, err := NewServer(pg, Config{})
	if err != nil {
		t.Fatal(err)
	}
	r := s.Router()
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))

	pupil := "STU-PGM-" + newID("X")
	addPupil(t, pg, pupil, "JHS2A")
	rec := do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/submit",
		`{"studentId":"`+pupil+`","answers":{"Q-MATH-001":"2/4","Q-MATH-002":"1/4 m"}}`, teacher)
	if rec.Code != http.StatusCreated {
		t.Fatalf("submit: %d %s", rec.Code, rec.Body.String())
	}
	rec = do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/verdicts",
		`{"studentId":"`+pupil+`","teacherMarks":{"Q-MATH-003":3.5}}`, teacher)
	if rec.Code != http.StatusOK {
		t.Fatalf("verdicts: %d %s", rec.Code, rec.Body.String())
	}
	sub, ok := pg.SubmissionFor("ASSMT-MAT-HALF", pupil)
	if !ok || sub.Earned != 5.5 || sub.TeacherMarks["Q-MATH-003"] != 3.5 || sub.Answers["Q-MATH-001"] != "2/4" {
		t.Fatalf("stored submission = %+v (found %v), want earned 5.5 with Q3 = 3.5", sub, ok)
	}
	if n, last, _ := pg.StoreErrors(); n != errsBefore {
		t.Errorf("%d storage error(s), last: %v", n-errsBefore, last)
	}
}

// TestMarkingDraftsOnPostgres drives drafting against PostgreSQL, where the
// draft tables have real foreign keys: answers link to scheme_questions, so
// a notes-only scheme edit must keep its row ids and a grade edit must fork.
func TestMarkingDraftsOnPostgres(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN not set; skipping PostgreSQL integration test")
	}
	pg, err := store.NewPostgres(dsn, false)
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(func() { pg.Close() })
	store.Seed(pg)
	errsBefore, _, _ := pg.StoreErrors()
	gin.SetMode(gin.TestMode)
	s, err := NewServer(pg, Config{})
	if err != nil {
		t.Fatal(err)
	}
	r := s.Router()
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")

	// A fresh pupil and paper per run, so the shared database needs no reset.
	pupil := "STU-PGD-" + newID("X")
	addPupil(t, pg, pupil, "JHS2A")
	rec := do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/submit",
		`{"studentId":"`+pupil+`","answers":{"Q-MATH-001":"2/4"}}`, bearer(teacher))
	if rec.Code != http.StatusCreated {
		t.Fatalf("submit: %d %s", rec.Code, rec.Body.String())
	}
	sub, _ := pg.SubmissionFor("ASSMT-MAT-HALF", pupil)

	scheme := createScheme(t, r, head, "ASSMT-MAT-HALF")
	body := fmt.Sprintf(`{"schemeId":%q,"submissionId":%q,"studentId":%q,"answers":[{"questionNumber":1,"text":"1/2"},{"questionNumber":2,"text":"11/12"}]}`,
		scheme.ID, sub.ID, pupil)
	rec = do(r, "POST", "/api/marking-drafts", body, bearer(teacher))
	if rec.Code != http.StatusCreated {
		t.Fatalf("draft: %d %s", rec.Code, rec.Body.String())
	}
	var created domain.MarkingDraft
	_ = json.Unmarshal(rec.Body.Bytes(), &created)

	got, ok := pg.MarkingDraftByID(created.ID)
	if !ok || got.DraftTotal != 6 || len(got.Answers) != 2 || got.Answers[0].SchemeQuestionID != scheme.Questions[0].ID ||
		got.Answers[0].DraftMarks != 3 || len(got.Answers[0].Reasons) == 0 || len(got.Answers[0].Steps) == 0 {
		t.Fatalf("draft reload: %+v", got)
	}

	// A notes-only edit keeps the rows the draft points at (a re-minted id
	// would break the foreign key or orphan the link).
	notes := strings.Replace(schemeQuestionsFixture, "Did not invert the divisor", "Reworded note", 1)
	rec = do(r, "PUT", "/api/marking-schemes/"+scheme.ID, `{"questions":`+notes+`}`, bearer(head))
	if rec.Code != http.StatusOK {
		t.Fatalf("notes edit: %d %s", rec.Code, rec.Body.String())
	}
	if qs := pg.SchemeQuestions(scheme.ID); len(qs) != 2 || qs[0].ID != scheme.Questions[0].ID ||
		qs[0].Misconceptions[0].LikelyCause != "Reworded note when dividing" {
		t.Fatalf("notes edit should update in place keeping ids: %+v", qs)
	}

	// A grade edit forks; deleting the drafted scheme is refused.
	regraded := strings.Replace(schemeQuestionsFixture, `"answerText": "11/12"`, `"answerText": "22/24"`, 1)
	rec = do(r, "PUT", "/api/marking-schemes/"+scheme.ID, `{"questions":`+regraded+`}`, bearer(head))
	var v2 domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &v2)
	if rec.Code != http.StatusOK || v2.ID == scheme.ID {
		t.Fatalf("grade edit should fork: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "DELETE", "/api/marking-schemes/"+scheme.ID, "", bearer(head)); rec.Code != http.StatusConflict {
		t.Errorf("delete drafted scheme: got %d, want 409", rec.Code)
	}

	// Redrafting against the new version discards the old draft.
	body = strings.Replace(body, scheme.ID, v2.ID, 1)
	if rec := do(r, "POST", "/api/marking-drafts", body, bearer(teacher)); rec.Code != http.StatusCreated {
		t.Fatalf("redraft: %d %s", rec.Code, rec.Body.String())
	}
	if old, _ := pg.MarkingDraftByID(created.ID); old.Status != domain.DraftStatusDiscarded {
		t.Errorf("old draft status = %q, want discarded", old.Status)
	}

	// The OCR reading saved by generate survives a reload from Postgres.
	gen := newGenRequest(t, r, teacher, `{"subjectId":"ENG","topic":"Essay","type":"mcq","count":1}`)
	if rec := do(r, "POST", "/api/questions/ai/requests/"+gen+"/generate", ``, bearer(teacher)); rec.Code != http.StatusOK {
		t.Fatalf("generate: %d %s", rec.Code, rec.Body.String())
	}
	if g, _ := pg.AIRequestByID(gen); len(g.OCRResult) == 0 || !strings.Contains(string(g.OCRResult), `"confirmed": false`) && !strings.Contains(string(g.OCRResult), `"confirmed":false`) {
		t.Errorf("saved OCR result = %s", g.OCRResult)
	}

	if n, last, _ := pg.StoreErrors(); n != errsBefore {
		t.Errorf("%d storage error(s), last: %v", n-errsBefore, last)
	}
}
