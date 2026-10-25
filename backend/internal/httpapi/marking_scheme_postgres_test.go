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
