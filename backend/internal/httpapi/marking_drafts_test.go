package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// =============================================================================
// Marking drafts — Phase 5
// =============================================================================
//
// The seed has SUB-M1-STU002: STU-002's paper for ASSMT-MAT-HALF (JHS2A).
// schemeQuestionsFixture: Q1 (4 marks) accepts "2/4" (4) or "1/2" (3) and
// names "34" as a misconception (1); Q2 (3 marks) accepts "11/12".

type draftReply struct {
	domain.MarkingDraft
	Final bool `json:"final"`
}

func postDraft(t *testing.T, r http.Handler, tok, body string) (int, draftReply, string) {
	t.Helper()
	rec := do(r, "POST", "/api/marking-drafts", body, bearer(tok))
	var d draftReply
	if rec.Code == http.StatusCreated {
		if err := json.Unmarshal(rec.Body.Bytes(), &d); err != nil {
			t.Fatalf("decode draft: %v", err)
		}
	}
	return rec.Code, d, rec.Body.String()
}

func typedDraft(schemeID string, answers string) string {
	return fmt.Sprintf(`{"schemeId":%q,"submissionId":"SUB-M1-STU002","studentId":"STU-002","answers":%s}`, schemeID, answers)
}

// saveOcrJob stores one of the caller's OCR readings the way the app mirrors it.
func saveOcrJob(t *testing.T, r http.Handler, tok, id, status, reviewed string) {
	t.Helper()
	confirmed := "null"
	if status == "confirmed" {
		confirmed = `"2026-10-25 09:00"`
	}
	body := fmt.Sprintf(`{"id":%q,"status":%q,"text":"engine text","reviewedText":%q,"confirmedAt":%s}`,
		id, status, reviewed, confirmed)
	if rec := do(r, "PUT", "/api/records/ocr_jobs/"+id, body, bearer(tok)); rec.Code != http.StatusOK {
		t.Fatalf("save ocr job: %d %s", rec.Code, rec.Body.String())
	}
}

func TestDraftFromTypedAnswers(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	// ASSMT-MAT-HALF is a diagnostic: an exam type, so a leader writes the
	// scheme and the teacher grades against it.
	scheme := createScheme(t, r, login(t, r, "head@school.gh", "head123"), "ASSMT-MAT-HALF")
	before, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-002")

	code, d, body := postDraft(t, r, teacher, typedDraft(scheme.ID,
		`[{"questionNumber":1,"text":"1/2"},{"questionNumber":2,"text":"5/6","working":["9/12 + 2/12"]}]`))
	if code != http.StatusCreated {
		t.Fatalf("create draft: %d %s", code, body)
	}
	if d.Final || d.Status != domain.DraftStatusDraft {
		t.Fatalf("a draft must not be final: %+v", d)
	}
	if d.DraftTotal != 3 || d.MaxTotal != 7 || d.NeedsReview != 1 || d.TargetKind != domain.DraftTargetAssessment {
		t.Errorf("draft totals: %v/%v, %d to review, kind %s", d.DraftTotal, d.MaxTotal, d.NeedsReview, d.TargetKind)
	}
	if len(d.Answers) != 2 {
		t.Fatalf("answers: %+v", d.Answers)
	}
	for i, a := range d.Answers {
		if a.SchemeQuestionID == "" || a.SchemeQuestionID != scheme.Questions[i].ID {
			t.Errorf("Q%d not linked to its scheme question: %q", a.QuestionNumber, a.SchemeQuestionID)
		}
		if len(a.Reasons) == 0 {
			t.Errorf("Q%d has no reason for its mark", a.QuestionNumber)
		}
	}
	if d.Answers[1].Method != "none" || !d.Answers[1].NeedsReview {
		t.Errorf("an answer outside the scheme must be flagged: %+v", d.Answers[1])
	}

	// The real marks are untouched: a draft is not a grade.
	after, _ := st.SubmissionFor("ASSMT-MAT-HALF", "STU-002")
	if after.Earned != before.Earned || len(after.TeacherMarks) != len(before.TeacherMarks) {
		t.Errorf("drafting changed the recorded marks: before %+v after %+v", before, after)
	}

	// It reloads intact.
	rec := do(r, "GET", "/api/marking-drafts/"+d.ID, "", bearer(teacher))
	var got draftReply
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if rec.Code != http.StatusOK || got.DraftTotal != 3 || len(got.Answers) != 2 || got.Final {
		t.Errorf("reload: %d %+v", rec.Code, got)
	}
}

// TestDraftOnlyFromConfirmedReadings: OCR output is never marked until a
// teacher has confirmed it, and the server reads the confirmed text from the
// teacher's own records rather than trusting the request.
func TestDraftOnlyFromConfirmedReadings(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	scheme := createScheme(t, r, head, "ASSMT-MAT-HALF")
	fromJobs := func(ids ...string) string {
		b, _ := json.Marshal(ids)
		return fmt.Sprintf(`{"schemeId":%q,"submissionId":"SUB-M1-STU002","studentId":"STU-002","ocrJobIds":%s}`, scheme.ID, b)
	}

	saveOcrJob(t, r, teacher, "OCR-READ", "read", "1. 2/4")
	if code, _, body := postDraft(t, r, teacher, fromJobs("OCR-READ")); code != http.StatusConflict || !strings.Contains(body, "not been confirmed") {
		t.Errorf("unconfirmed reading: %d %s", code, body)
	}

	saveOcrJob(t, r, head, "OCR-HEAD", "confirmed", "1. 2/4")
	if code, _, _ := postDraft(t, r, teacher, fromJobs("OCR-HEAD")); code != http.StatusConflict {
		t.Errorf("another teacher's reading: got %d, want 409", code)
	}

	// The teacher's correction is what gets marked, not the engine's text.
	saveOcrJob(t, r, teacher, "OCR-P1", "confirmed", "Name: Akosua\n1. 2/4")
	saveOcrJob(t, r, teacher, "OCR-P2", "confirmed", "2) 9/12 + 2/12\n= 11/12")
	code, d, body := postDraft(t, r, teacher, fromJobs("OCR-P1", "OCR-P2"))
	if code != http.StatusCreated {
		t.Fatalf("draft from confirmed pages: %d %s", code, body)
	}
	if d.DraftTotal != 7 || d.NeedsReview != 0 {
		t.Errorf("draft = %v with %d to review, want 7 and 0: %+v", d.DraftTotal, d.NeedsReview, d.Answers)
	}
	if !strings.Contains(d.SourceText, "Name: Akosua") || len(d.Unassigned) != 1 || len(d.OcrJobIDs) != 2 {
		t.Errorf("source and unassigned text must be kept: %q %v %v", d.SourceText, d.Unassigned, d.OcrJobIDs)
	}
}

func TestDraftRoles(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	scheme := createScheme(t, r, login(t, r, "head@school.gh", "head123"), "ASSMT-MAT-HALF")
	body := typedDraft(scheme.ID, `[{"questionNumber":1,"text":"2/4"}]`)

	code, d, _ := postDraft(t, r, teacher, body)
	if code != http.StatusCreated {
		t.Fatalf("teacher: %d", code)
	}
	for _, who := range [][2]string{
		{"kojo.owusu@school.gh", "student123"},
		{"ama.owusu@school.gh", "parent123"},
		{"staff@school.gh", "staff123"},
	} {
		tok := login(t, r, who[0], who[1])
		if code, _, _ := postDraft(t, r, tok, body); code != http.StatusForbidden {
			t.Errorf("%s create: got %d, want 403", who[0], code)
		}
		if rec := do(r, "GET", "/api/marking-drafts/"+d.ID, "", bearer(tok)); rec.Code != http.StatusForbidden {
			t.Errorf("%s read: got %d, want 403", who[0], rec.Code)
		}
	}
	if code, _, _ := postDraft(t, r, login(t, r, "head@school.gh", "head123"), body); code != http.StatusCreated {
		t.Errorf("headteacher: got %d, want 201", code)
	}

	// A teacher cannot draft, or read drafts, for another class.
	addPupil(t, st, "STU-OTHER", "JHS1B")
	if err := st.SaveAssessment(domain.Assessment{ID: "ASSMT-OTHER", Title: "Other", Type: domain.TypeClassTest,
		SubjectID: "MATH", ClassID: "JHS1B"}); err != nil {
		t.Fatal(err)
	}
	other := createScheme(t, r, login(t, r, "head@school.gh", "head123"), "ASSMT-OTHER")
	if err := st.SaveSubmission(domain.Submission{ID: "SUB-OTHER", AssessmentID: "ASSMT-OTHER",
		StudentID: "STU-OTHER", ClassID: "JHS1B", Date: "2026-09-10"}); err != nil {
		t.Fatal(err)
	}
	otherBody := fmt.Sprintf(`{"schemeId":%q,"submissionId":"SUB-OTHER","studentId":"STU-OTHER","answers":[{"questionNumber":1,"text":"2/4"}]}`, other.ID)
	if code, _, _ := postDraft(t, r, teacher, otherBody); code != http.StatusForbidden {
		t.Errorf("teacher, other class: got %d, want 403", code)
	}

	// The paper must be this student's, for this scheme's assessment.
	wrongPaper := strings.Replace(body, "SUB-M1-STU002", "SUB-M1-STU001", 1)
	if code, _, _ := postDraft(t, r, teacher, wrongPaper); code != http.StatusNotFound {
		t.Errorf("someone else's paper: got %d, want 404", code)
	}
}

// TestDraftsProtectTheSchemeTheyUsed: a scheme with drafts counts as marked,
// so changing its marks forks a new version and it cannot be deleted; a new
// draft replaces the previous one; and drafting against an old version is
// refused.
func TestDraftsProtectTheSchemeTheyUsed(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	scheme := createScheme(t, r, head, "ASSMT-MAT-HALF")
	body := typedDraft(scheme.ID, `[{"questionNumber":1,"text":"2/4"}]`)
	_, first, _ := postDraft(t, r, teacher, body)
	_, second, _ := postDraft(t, r, teacher, body)

	rec := do(r, "GET", "/api/marking-drafts?submissionId=SUB-M1-STU002", "", bearer(teacher))
	var list []draftReply
	_ = json.Unmarshal(rec.Body.Bytes(), &list)
	statuses := map[string]string{}
	for _, d := range list {
		statuses[d.ID] = d.Status
	}
	if statuses[first.ID] != domain.DraftStatusDiscarded || statuses[second.ID] != domain.DraftStatusDraft {
		t.Errorf("redraft should discard the earlier draft: %v", statuses)
	}

	if rec := do(r, "DELETE", "/api/marking-schemes/"+scheme.ID, "", bearer(head)); rec.Code != http.StatusConflict {
		t.Errorf("deleting a drafted scheme: got %d, want 409", rec.Code)
	}

	// A notes-only edit stays in place and keeps the rows drafts point at.
	notes := strings.Replace(schemeQuestionsFixture, "Did not invert the divisor", "Reworded note", 1)
	rec = do(r, "PUT", "/api/marking-schemes/"+scheme.ID, `{"questions":`+notes+`}`, bearer(head))
	var same domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &same)
	if rec.Code != http.StatusOK || same.ID != scheme.ID || same.Questions[0].ID != scheme.Questions[0].ID {
		t.Fatalf("notes-only edit must keep the scheme and its row ids: %d %+v", rec.Code, same)
	}

	// A grade-relevant edit forks a new version.
	regraded := strings.Replace(schemeQuestionsFixture, `"answerText": "11/12"`, `"answerText": "22/24"`, 1)
	rec = do(r, "PUT", "/api/marking-schemes/"+scheme.ID, `{"questions":`+regraded+`}`, bearer(head))
	var v2 domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &v2)
	if rec.Code != http.StatusOK || v2.ID == scheme.ID || v2.Version != scheme.Version+1 {
		t.Fatalf("grade edit on a drafted scheme must fork: %d %+v", rec.Code, v2)
	}
	if code, _, body := postDraft(t, r, teacher, body); code != http.StatusConflict || !strings.Contains(body, "latest") {
		t.Errorf("drafting against the old version: %d %s", code, body)
	}
}

func TestDraftForAnAssignment(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	rec := do(r, "POST", "/api/assignments/ASG-001/marking-scheme",
		`{"assignmentId":"ASG-001","questions":`+schemeQuestionsFixture+`}`, bearer(teacher))
	if rec.Code != http.StatusCreated {
		t.Fatalf("assignment scheme: %d %s", rec.Code, rec.Body.String())
	}
	var scheme domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &scheme)
	rec = do(r, "PUT", "/api/records/assignment_submissions/ASUB-1",
		`{"id":"ASUB-1","assignmentId":"ASG-001","studentId":"STU-002","classId":"JHS2A","pages":[]}`, bearer(teacher))
	if rec.Code != http.StatusOK {
		t.Fatalf("assignment submission: %d %s", rec.Code, rec.Body.String())
	}
	code, d, body := postDraft(t, r, teacher, fmt.Sprintf(
		`{"schemeId":%q,"submissionId":"ASUB-1","studentId":"STU-002","answers":[{"questionNumber":2,"text":"11/12"}]}`, scheme.ID))
	if code != http.StatusCreated || d.TargetKind != domain.DraftTargetAssignment || d.DraftTotal != 3 {
		t.Fatalf("assignment draft: %d %+v %s", code, d, body)
	}
	// Another student's submission id is refused.
	code, _, _ = postDraft(t, r, teacher, fmt.Sprintf(
		`{"schemeId":%q,"submissionId":"ASUB-1","studentId":"STU-001","answers":[{"questionNumber":2,"text":"11/12"}]}`, scheme.ID))
	if code != http.StatusNotFound {
		t.Errorf("mismatched student: got %d, want 404", code)
	}
}

// TestOcrReadingIsSavedForItsRequester covers the Phase 4 follow-up: the
// reading is kept, can be fetched again by the teacher who asked for it, and
// by nobody else.
func TestOcrReadingIsSavedForItsRequester(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	id := newGenRequest(t, r, teacher, `{"subjectId":"ENG","topic":"Essay","type":"mcq","count":1}`)

	if rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(head)); rec.Code != http.StatusForbidden {
		t.Errorf("generate on someone else's request: got %d, want 403", rec.Code)
	}
	if rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(teacher)); rec.Code != http.StatusOK {
		t.Fatalf("generate: %d %s", rec.Code, rec.Body.String())
	}
	// The retry still refuses to read (and bill) twice…
	if rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(teacher)); rec.Code != http.StatusConflict {
		t.Errorf("second generate: got %d, want 409", rec.Code)
	}
	// …but the reading is recoverable, and never marked confirmed.
	rec := do(r, "GET", "/api/questions/ai/requests/"+id+"/ocr", "", bearer(teacher))
	var saved struct {
		Text      string `json:"text"`
		Provider  string `json:"provider"`
		Confirmed bool   `json:"confirmed"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &saved)
	if rec.Code != http.StatusOK || saved.Text == "" || saved.Provider != "mock" || saved.Confirmed {
		t.Errorf("saved reading: %d %+v", rec.Code, saved)
	}
	if rec := do(r, "GET", "/api/questions/ai/requests/"+id+"/ocr", "", bearer(head)); rec.Code != http.StatusNotFound {
		t.Errorf("another user fetching the reading: got %d, want 404", rec.Code)
	}
	// The shared request list carries the reading for its owner only.
	for tok, want := range map[string]bool{teacher: true, head: false} {
		rec := do(r, "GET", "/api/questions/ai/requests", "", bearer(tok))
		var list []domain.GenRequest
		_ = json.Unmarshal(rec.Body.Bytes(), &list)
		for _, g := range list {
			if g.ID == id && (len(g.OCRResult) > 0) != want {
				t.Errorf("list for owner=%v carries the reading: %v", want, len(g.OCRResult) > 0)
			}
		}
	}
}
