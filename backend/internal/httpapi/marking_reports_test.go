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
// Feedback reports — Phase 7
// =============================================================================

type studentFeedback struct {
	Student struct {
		ID string `json:"id"`
	} `json:"student"`
	Papers []feedbackPaper `json:"papers"`
	Summary struct {
		Papers         int          `json:"papers"`
		WrongQuestions int          `json:"wrongQuestions"`
		Misconceptions []causeCount `json:"misconceptions"`
	} `json:"summary"`
}

type classFeedback struct {
	ClassID        string             `json:"classId"`
	Reports        []classPaperReport `json:"reports"`
	AwaitingReview int                `json:"awaitingReview"`
}

func getJSON(t *testing.T, r http.Handler, tok, path string, out any) int {
	t.Helper()
	rec := do(r, "GET", path, "", bearer(tok))
	if rec.Code == http.StatusOK && out != nil {
		if err := json.Unmarshal(rec.Body.Bytes(), out); err != nil {
			t.Fatalf("decode %s: %v", path, err)
		}
	}
	return rec.Code
}

// misconceptionScheme is matchingSchemeFixture with one known wrong answer
// on Q2: "1/2 m", from halving the wrong quantity.
var misconceptionScheme = strings.Replace(matchingSchemeFixture,
	`"acceptedAnswers":[{"answerText":"3/8 m","normalizedForm":"38m","marksAwarded":3,"isPrimary":true}],
   "misconceptions":[]`,
	`"acceptedAnswers":[{"answerText":"3/8 m","normalizedForm":"38m","marksAwarded":3,"isPrimary":true}],
   "misconceptions":[{"wrongAnswerPattern":"1/2 m","likelyCause":"Took half of 1 m instead of half of 3/4 m","marksAwarded":0}]`, 1)

func finalizeDraft(t *testing.T, r http.Handler, tok string, d draftReply, marks map[int]float64, notes map[int]string) {
	t.Helper()
	rec := do(r, "POST", "/api/marking-drafts/"+d.ID+"/finalize", finalizeBody(d, marks, notes), bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("finalize %s: %d %s", d.ID, rec.Code, rec.Body.String())
	}
}

func TestFeedbackReportsUseOnlyFinalizedMarks(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	parent := login(t, r, "akua.boaduwaa@school.gh", "parent123")
	_, d := draftForSTU002(t, r, teacher, head)

	// A draft nobody has reviewed is not feedback.
	var sf studentFeedback
	if code := getJSON(t, r, teacher, "/api/reports/marking/students/STU-002", &sf); code != http.StatusOK || len(sf.Papers) != 0 {
		t.Fatalf("before finalize: %d, %d papers; want 200 and none", code, len(sf.Papers))
	}
	var cf classFeedback
	if code := getJSON(t, r, teacher, "/api/reports/marking/classes/JHS2A", &cf); code != http.StatusOK ||
		len(cf.Reports) != 0 || cf.AwaitingReview != 1 {
		t.Fatalf("class before finalize: %d %+v; want no reports and 1 awaiting review", code, cf)
	}

	finalizeDraft(t, r, teacher, d, map[int]float64{1: 2, 2: 1, 3: 4}, map[int]string{2: "Method right, final step wrong"})

	if code := getJSON(t, r, teacher, "/api/reports/marking/students/STU-002", &sf); code != http.StatusOK || len(sf.Papers) != 1 {
		t.Fatalf("after finalize: %d, %d papers", code, len(sf.Papers))
	}
	p := sf.Papers[0]
	if p.Marks != 7 || p.Total != 9 || p.Title != "Fractions Quick Diagnostic" || p.FullMarks != 2 || len(p.Wrong) != 1 {
		t.Fatalf("paper: %+v", p)
	}
	q := p.Wrong[0]
	// The scheme knows no misconception for "1/2 m" here, so none is named;
	// the next step comes from the question's topic instead.
	if q.QuestionNumber != 2 || q.Marks != 1 || q.TotalMarks != 3 || q.LikelyMisconception != "" ||
		q.NextStepSource != nextStepTopic || q.NextStep != "Practise Fractions." || q.TeacherNote == "" {
		t.Errorf("wrong question: %+v", q)
	}

	// The family sees the same feedback without the marker's private note.
	var pf studentFeedback
	if code := getJSON(t, r, parent, "/api/reports/marking/students/STU-002", &pf); code != http.StatusOK ||
		len(pf.Papers) != 1 || pf.Papers[0].Wrong[0].TeacherNote != "" {
		t.Errorf("parent view: %d %+v", code, pf)
	}
	// No answer key reaches the report.
	rec := do(r, "GET", "/api/reports/marking/students/STU-002", "", bearer(parent))
	if body := rec.Body.String(); strings.Contains(body, "3/8") || strings.Contains(body, "acceptedAnswers") {
		t.Errorf("the report leaks the scheme's answers: %s", body)
	}
}

func TestFeedbackNamesKnownMisconceptionsAndClassStruggles(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	rec := do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/marking-scheme",
		`{"assessmentId":"ASSMT-MAT-HALF","questions":`+misconceptionScheme+`}`, bearer(head))
	if rec.Code != http.StatusCreated {
		t.Fatalf("scheme: %d %s", rec.Code, rec.Body.String())
	}
	var scheme domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &scheme)

	// STU-002 wrote the known wrong answer; STU-001 got Q2 right but the
	// teacher gave one mark after checking the working; Q3 a blank for STU-002.
	code, d2, body := postDraft(t, r, teacher, typedDraft(scheme.ID,
		`[{"questionNumber":1,"text":"2/4"},{"questionNumber":2,"text":"1/2 m"}]`))
	if code != http.StatusCreated {
		t.Fatalf("draft STU-002: %d %s", code, body)
	}
	code, d1, body := postDraft(t, r, teacher, fmt.Sprintf(
		`{"schemeId":%q,"studentId":"STU-001","answers":[{"questionNumber":1,"text":"2/4"},{"questionNumber":2,"text":"3/8 m"},{"questionNumber":3,"text":"11/12"}]}`,
		scheme.ID))
	if code != http.StatusCreated {
		t.Fatalf("draft STU-001: %d %s", code, body)
	}
	finalizeDraft(t, r, teacher, d2, map[int]float64{1: 2, 2: 0, 3: 0}, nil)
	finalizeDraft(t, r, teacher, d1, map[int]float64{1: 2, 2: 1, 3: 4}, map[int]string{2: "Answer copied, no working"})

	var sf studentFeedback
	if code := getJSON(t, r, teacher, "/api/reports/marking/students/STU-002", &sf); code != http.StatusOK || len(sf.Papers) != 1 {
		t.Fatalf("student report: %d %+v", code, sf)
	}
	wrong := sf.Papers[0].Wrong
	if len(wrong) != 2 {
		t.Fatalf("want Q2 and Q3 wrong, got %+v", wrong)
	}
	if w := wrong[0]; w.QuestionNumber != 2 || w.LikelyMisconception != "Took half of 1 m instead of half of 3/4 m" ||
		w.NextStepSource != nextStepMisconception {
		t.Errorf("Q2: %+v", w)
	}
	if w := wrong[1]; w.QuestionNumber != 3 || !w.Blank || w.NextStepSource != nextStepBlank {
		t.Errorf("Q3: %+v", w)
	}
	if len(sf.Summary.Misconceptions) != 1 || sf.Summary.WrongQuestions != 2 {
		t.Errorf("summary: %+v", sf.Summary)
	}

	var cf classFeedback
	if code := getJSON(t, r, teacher, "/api/reports/marking/classes/JHS2A", &cf); code != http.StatusOK || len(cf.Reports) != 1 {
		t.Fatalf("class report: %d %+v", code, cf)
	}
	rep := cf.Reports[0]
	if rep.Papers != 2 || rep.AwaitingReview != 0 || len(rep.Questions) != 3 {
		t.Fatalf("class paper: %+v", rep)
	}
	q1, q2, q3 := rep.Questions[0], rep.Questions[1], rep.Questions[2]
	if q1.Struggled || q1.FullMarks != 2 || q1.AveragePercent != 100 {
		t.Errorf("Q1: %+v", q1)
	}
	// Q2: 0 and 1 of 3 — the class struggled, and the misconception is
	// counted once (STU-001 lost marks without one).
	if !q2.Struggled || q2.AverageMarks != 0.5 || len(q2.BelowFull) != 2 || q2.BelowFull[0].StudentID != "STU-002" ||
		len(q2.Misconceptions) != 1 || q2.Misconceptions[0].Count != 1 {
		t.Errorf("Q2: %+v", q2)
	}
	// Q3: 0 and 4 of 4 is exactly 50% — not below the threshold.
	if q3.Struggled || q3.Blank != 1 || q3.Zero != 1 {
		t.Errorf("Q3: %+v", q3)
	}
	if len(rep.Hardest) != 1 || rep.Hardest[0] != 2 {
		t.Errorf("hardest = %v, want [2]", rep.Hardest)
	}
}

func TestFeedbackReportAccess(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	admin := login(t, r, "admin@solvanta.app", "admin123")
	_, d := draftForSTU002(t, r, teacher, head)
	finalizeDraft(t, r, teacher, d, map[int]float64{1: 2, 2: 0, 3: 4}, nil)

	if rec := do(r, "POST", "/api/users",
		`{"name":"Kofi Ame","email":"kofi.ame@school.gh","password":"Teacher123","role":"teacher","classId":"JHS1A"}`,
		bearer(admin)); rec.Code != http.StatusCreated {
		t.Fatalf("create teacher: %d %s", rec.Code, rec.Body.String())
	}
	other := login(t, r, "kofi.ame@school.gh", "Teacher123")
	otherParent := login(t, r, "ama.owusu@school.gh", "parent123")
	student := login(t, r, "kojo.owusu@school.gh", "student123") // STU-001
	staff := login(t, r, "staff@school.gh", "staff123")

	cases := []struct {
		who, tok, path string
		want           int
	}{
		{"own teacher, student", teacher, "/api/reports/marking/students/STU-002", http.StatusOK},
		{"own teacher, class", teacher, "/api/reports/marking/classes/JHS2A", http.StatusOK},
		{"headteacher, class", head, "/api/reports/marking/classes/JHS2A", http.StatusOK},
		{"staff, class", staff, "/api/reports/marking/classes/JHS2A", http.StatusOK},
		{"other class teacher, student", other, "/api/reports/marking/students/STU-002", http.StatusForbidden},
		{"other class teacher, class", other, "/api/reports/marking/classes/JHS2A", http.StatusForbidden},
		{"another family's parent", otherParent, "/api/reports/marking/students/STU-002", http.StatusForbidden},
		{"another pupil", student, "/api/reports/marking/students/STU-002", http.StatusForbidden},
		{"pupil, own report", student, "/api/reports/marking/students/STU-001", http.StatusOK},
		{"parent, class", otherParent, "/api/reports/marking/classes/JHS2A", http.StatusForbidden},
		{"pupil, class", student, "/api/reports/marking/classes/JHS2A", http.StatusForbidden},
		{"unknown student", teacher, "/api/reports/marking/students/STU-NOPE", http.StatusNotFound},
	}
	for _, c := range cases {
		if code := getJSON(t, r, c.tok, c.path, nil); code != c.want {
			t.Errorf("%s: got %d, want %d", c.who, code, c.want)
		}
	}
}
