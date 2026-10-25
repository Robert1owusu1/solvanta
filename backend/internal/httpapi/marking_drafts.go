package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/marking"
	"solvanta/backend/internal/matching"
)

// =============================================================================
// Marking drafts — Phase 5
// =============================================================================
//
// A draft is the matching engine's proposal for one student's paper. It is
// built only from text a teacher has confirmed (a confirmed OCR reading, or
// answers the teacher typed), it is stored apart from the real marks, and it
// is never final: turning it into marks is an explicit teacher action in the
// review screen (Phase 6). Drafting is grading, so it follows the marking
// rule — a teacher for their own class, school leaders for any.

type draftAnswerInput struct {
	QuestionNumber int      `json:"questionNumber"`
	Text           string   `json:"text"`
	Working        []string `json:"working"`
}

type createDraftRequest struct {
	SchemeID string `json:"schemeId"`
	// SubmissionID names the paper. Required for an assignment; optional for
	// an assessment, whose one paper per student is found from the scheme's
	// assessment and the student — the app's local id for a captured paper
	// is not the server's.
	SubmissionID string `json:"submissionId"`
	StudentID    string `json:"studentId"`
	// Exactly one source: confirmed OCR readings (read from the teacher's
	// own ocr_jobs records, never from this body), or answers typed by the
	// teacher — the manual route when there is no usable photo.
	OcrJobIDs []string           `json:"ocrJobIds"`
	Answers   []draftAnswerInput `json:"answers"`
}

// draftResponse adds what every client must respect: whether these are
// recorded marks (only once a teacher has finalized), and their total.
type draftResponse struct {
	domain.MarkingDraft
	Final      bool    `json:"final"`
	FinalTotal float64 `json:"finalTotal"`
}

func toDraftResponse(d domain.MarkingDraft) draftResponse {
	final := d.Status == domain.DraftStatusFinalized
	r := draftResponse{MarkingDraft: d, Final: final}
	if final {
		r.FinalTotal = d.FinalTotal()
	}
	return r
}

func respondDraft(c *gin.Context, status int, d domain.MarkingDraft) {
	c.JSON(status, toDraftResponse(d))
}

func (s *Server) createMarkingDraft(c *gin.Context) {
	u := currentUser(c)
	var body createDraftRequest
	if !bind(c, &body) {
		return
	}
	if body.SchemeID == "" || body.StudentID == "" {
		fail(c, http.StatusBadRequest, "schemeId and studentId are required")
		return
	}
	if (len(body.OcrJobIDs) > 0) == (len(body.Answers) > 0) {
		fail(c, http.StatusBadRequest, "Send either ocrJobIds or answers, not both")
		return
	}

	scheme, ok := s.store.MarkingSchemeByID(body.SchemeID)
	if !ok {
		fail(c, http.StatusNotFound, "Marking scheme not found")
		return
	}
	classID, _ := s.schemeTarget(scheme)
	if classID == "" {
		fail(c, http.StatusNotFound, "The scheme's assessment or assignment no longer exists")
		return
	}
	if !teacherCoversClass(u, classID) {
		fail(c, http.StatusForbidden, "You may only mark work for your own class")
		return
	}
	if latest := s.store.LatestSchemeVersion(scheme.AssessmentID, scheme.AssignmentID); scheme.Version < latest {
		fail(c, http.StatusConflict, fmt.Sprintf(
			"This is version %d of the scheme; mark against the latest, version %d", scheme.Version, latest))
		return
	}

	st, ok := s.store.StudentByID(body.StudentID)
	if !ok || st.ClassID != classID {
		fail(c, http.StatusBadRequest, "That student is not in the class this scheme is for")
		return
	}
	kind, submissionID, msg := s.checkDraftSubmission(scheme, body.SubmissionID, st.ID)
	if msg != "" {
		fail(c, http.StatusNotFound, msg)
		return
	}
	body.SubmissionID = submissionID

	questions := s.store.SchemeQuestions(scheme.ID)
	if len(questions) == 0 {
		fail(c, http.StatusConflict, "The scheme has no questions to mark against")
		return
	}

	// Build the answers from the chosen, teacher-confirmed source.
	var answers []matching.Answer
	var unassigned []string
	var source string
	if len(body.OcrJobIDs) > 0 {
		text, msg := s.confirmedReading(u, body.OcrJobIDs)
		if msg != "" {
			fail(c, http.StatusConflict, msg)
			return
		}
		source = text
		single := 0
		if len(questions) == 1 {
			single = questions[0].QuestionNumber
		}
		answers, unassigned = matching.SplitAnswers(text, single)
	} else {
		var lines []string
		for _, a := range body.Answers {
			answers = append(answers, matching.Answer{QuestionNumber: a.QuestionNumber, Text: a.Text, Working: a.Working})
			lines = append(lines, fmt.Sprintf("%d. %s", a.QuestionNumber, a.Text))
		}
		source = strings.Join(lines, "\n")
	}

	// One live draft per paper: an earlier draft is discarded, and a paper
	// already finalized is changed in the review screen, not re-drafted.
	previous := s.store.MarkingDraftsForSubmission(body.SubmissionID)
	for _, d := range previous {
		if d.Status == domain.DraftStatusFinalized {
			fail(c, http.StatusConflict, "This paper's marks are already finalized; change them in the review screen")
			return
		}
	}

	result := matching.MarkScript(questions, answers, unassigned)
	draft := domain.MarkingDraft{
		ID:            newID("MD"),
		SchemeID:      scheme.ID,
		SchemeVersion: scheme.Version,
		TargetKind:    kind,
		SubmissionID:  body.SubmissionID,
		StudentID:     st.ID,
		ClassID:       classID,
		SourceText:    source,
		OcrJobIDs:     append([]string{}, body.OcrJobIDs...),
		Unassigned:    result.Unassigned,
		Status:        domain.DraftStatusDraft,
		DraftTotal:    result.DraftTotal,
		MaxTotal:      result.MaxTotal,
		NeedsReview:   result.NeedsReview,
		CreatedBy:     u.ID,
		CreatedAt:     now(),
		Answers:       draftAnswers(result),
	}
	if writeFailed(c, s.store.SaveMarkingDraft(draft)) {
		return
	}
	for _, d := range previous {
		if d.Status == domain.DraftStatusDraft {
			_ = s.store.SetMarkingDraftStatus(d.ID, domain.DraftStatusDiscarded)
		}
	}
	s.audit(c, "marking.draft", draft.ID, fmt.Sprintf("Drafted %s/%s for %s against scheme v%d (%d to review)",
		formatMarks(draft.DraftTotal), formatMarks(draft.MaxTotal), st.FullName(), scheme.Version, draft.NeedsReview), "")
	respondDraft(c, http.StatusCreated, draft)
}

// checkDraftSubmission confirms the paper exists, belongs to this student and
// is for the scheme's assessment or assignment. It returns the draft's target
// kind and the paper's server id, or a message saying what is wrong.
func (s *Server) checkDraftSubmission(scheme domain.MarkingScheme, submissionID, studentID string) (string, string, string) {
	if scheme.AssessmentID != "" {
		sub, ok := s.store.SubmissionFor(scheme.AssessmentID, studentID)
		if !ok || (submissionID != "" && sub.ID != submissionID) {
			return "", "", "No such submission from this student for the scheme's assessment"
		}
		return domain.DraftTargetAssessment, sub.ID, ""
	}
	if submissionID == "" {
		return "", "", "submissionId is required for an assignment"
	}
	rec, ok := s.store.RecordByID(domain.RecordAssignmentSubmissions, submissionID)
	if !ok {
		return "", "", "No such submission from this student for the scheme's assignment"
	}
	var data struct {
		AssignmentID string `json:"assignmentId"`
		StudentID    string `json:"studentId"`
	}
	if json.Unmarshal(rec.Data, &data) != nil || data.AssignmentID != scheme.AssignmentID || data.StudentID != studentID {
		return "", "", "No such submission from this student for the scheme's assignment"
	}
	return domain.DraftTargetAssignment, submissionID, ""
}

// confirmedReading joins the teacher-confirmed text of the caller's own OCR
// jobs, in the order given. A reading nobody has confirmed is refused, never
// marked: OCR output is not trusted as an answer until a teacher says so.
func (s *Server) confirmedReading(u domain.User, ids []string) (string, string) {
	var parts []string
	seen := map[string]bool{}
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		rec, ok := s.store.RecordByID(domain.RecordOcrJobs, id)
		if !ok || rec.OwnerID != u.ID {
			return "", fmt.Sprintf("OCR reading %s was not found among your readings; it may not have synced yet", id)
		}
		var job struct {
			Status       string  `json:"status"`
			Text         string  `json:"text"`
			ReviewedText *string `json:"reviewedText"`
			ConfirmedAt  *string `json:"confirmedAt"`
		}
		if json.Unmarshal(rec.Data, &job) != nil {
			return "", fmt.Sprintf("OCR reading %s could not be read", id)
		}
		if job.Status != "confirmed" || job.ConfirmedAt == nil || *job.ConfirmedAt == "" {
			return "", fmt.Sprintf("OCR reading %s has not been confirmed by a teacher yet", id)
		}
		text := job.Text
		if job.ReviewedText != nil {
			text = *job.ReviewedText
		}
		parts = append(parts, text)
	}
	return strings.Join(parts, "\n"), ""
}

// draftAnswers converts the engine's result to the stored form.
func draftAnswers(r matching.Result) []domain.MarkingDraftAnswer {
	out := make([]domain.MarkingDraftAnswer, 0, len(r.Questions))
	for _, q := range r.Questions {
		steps := make([]domain.DraftStep, 0, len(q.Steps))
		for _, st := range q.Steps {
			steps = append(steps, domain.DraftStep{StepID: st.StepID, Type: st.Type, Criteria: st.Criteria,
				Marks: st.Marks, Awarded: st.Awarded, Status: string(st.Status)})
		}
		working := q.Working
		if working == nil {
			working = []string{}
		}
		out = append(out, domain.MarkingDraftAnswer{
			SchemeQuestionID: q.SchemeQuestionID,
			QuestionNumber:   q.QuestionNumber,
			StudentAnswer:    q.StudentAnswer,
			Working:          working,
			DraftMarks:       q.DraftMarks,
			TotalMarks:       q.TotalMarks,
			Method:           string(q.Method),
			MatchedText:      q.MatchedText,
			MatchedAnswerID:  q.MatchedAnswerID,
			MisconceptionID:  q.MisconceptionID,
			LikelyCause:      q.LikelyCause,
			NeedsReview:      q.NeedsReview,
			Reasons:          q.Reasons,
			Steps:            steps,
		})
	}
	return out
}

// listMarkingDrafts returns a paper's drafts (?submissionId=, with answers,
// newest last) or the review queue (?status=draft, headers only) for the
// classes the caller marks.
func (s *Server) listMarkingDrafts(c *gin.Context) {
	u := currentUser(c)
	submissionID, status := c.Query("submissionId"), c.Query("status")
	var drafts []domain.MarkingDraft
	switch {
	case submissionID != "":
		drafts = s.store.MarkingDraftsForSubmission(submissionID)
	case status == domain.DraftStatusDraft || status == domain.DraftStatusFinalized:
		drafts = s.store.MarkingDraftsWithStatus(status)
	default:
		fail(c, http.StatusBadRequest, "Give submissionId, or status=draft|finalized")
		return
	}
	out := []draftResponse{}
	for _, d := range drafts {
		if teacherCoversClass(u, d.ClassID) {
			out = append(out, toDraftResponse(d))
		}
	}
	sendJSON(c, out)
}

// finalizeRequest carries the teacher's decision for every question.
type finalizeRequest struct {
	Marks []struct {
		SchemeQuestionID string  `json:"schemeQuestionId"`
		Marks            float64 `json:"marks"`
		Note             string  `json:"note"`
	} `json:"marks"`
}

// finalizeMarkingDraft records a reviewed draft as the paper's marks. It is
// the only way a draft becomes marks, and it needs an explicit mark for
// every question: there is no "accept the draft" shortcut on the server, so
// a client cannot finalize what the teacher has not seen.
func (s *Server) finalizeMarkingDraft(c *gin.Context) {
	u := currentUser(c)
	d, ok := s.store.MarkingDraftByID(c.Param("id"))
	if !ok || !teacherCoversClass(u, d.ClassID) {
		fail(c, http.StatusNotFound, "Draft not found")
		return
	}
	if d.Status != domain.DraftStatusDraft {
		fail(c, http.StatusConflict, "Only a current draft can be finalized (this one is "+d.Status+")")
		return
	}
	var body finalizeRequest
	if !bind(c, &body) {
		return
	}
	decided := map[string]int{}
	for i, m := range body.Marks {
		if _, dup := decided[m.SchemeQuestionID]; dup {
			fail(c, http.StatusBadRequest, "Each question may be given only one mark")
			return
		}
		decided[m.SchemeQuestionID] = i
	}
	if len(decided) != len(d.Answers) {
		fail(c, http.StatusBadRequest, "Give a final mark for every question before finalizing")
		return
	}
	for i := range d.Answers {
		a := &d.Answers[i]
		j, ok := decided[a.SchemeQuestionID]
		if !ok {
			fail(c, http.StatusBadRequest, fmt.Sprintf("Question %d has no final mark", a.QuestionNumber))
			return
		}
		m := body.Marks[j]
		if _, cents := cents(m.Marks); !cents || m.Marks < 0 || m.Marks > a.TotalMarks {
			fail(c, http.StatusBadRequest, fmt.Sprintf(
				"Question %d: the mark must be between 0 and %s, with at most two decimal places",
				a.QuestionNumber, formatMarks(a.TotalMarks)))
			return
		}
		v := m.Marks
		a.FinalMarks = &v
		a.TeacherNote = strings.TrimSpace(m.Note)
	}

	scheme, ok := s.store.MarkingSchemeByID(d.SchemeID)
	if !ok {
		fail(c, http.StatusConflict, "The scheme this draft used no longer exists")
		return
	}
	d.Status = domain.DraftStatusFinalized
	d.FinalizedBy = u.ID
	d.FinalizedAt = now()

	// An assessment paper's recorded score is updated to exactly what the
	// teacher finalized. An assignment has no other mark store: the
	// finalized draft is its record.
	var previous *domain.Submission
	if d.TargetKind == domain.DraftTargetAssessment {
		sub, msg := s.finalizedSubmission(scheme, d)
		if msg != "" {
			fail(c, http.StatusConflict, msg)
			return
		}
		if old, found := s.store.SubmissionFor(sub.AssessmentID, sub.StudentID); found {
			previous = &old
		}
		if writeFailed(c, s.store.SaveSubmission(sub)) {
			return
		}
	}
	if err := s.store.SaveMarkingDraft(d); err != nil {
		if previous != nil {
			_ = s.store.SaveSubmission(*previous) // keep the recorded marks as they were
		}
		writeFailed(c, err)
		return
	}

	st, _ := s.store.StudentByID(d.StudentID)
	total := d.FinalTotal()
	if st.ParentUserID != "" {
		var pct float64
		if d.MaxTotal > 0 {
			pct = 100 * total / d.MaxTotal
		}
		s.notify(st.ParentUserID, domain.NotifMarking, "Work marked",
			st.FullName()+" scored "+formatMarks(total)+"/"+formatMarks(d.MaxTotal)+" ("+marking.GradeLetter(pct)+").",
			st.ID)
	}
	overridden := 0
	for _, a := range d.Answers {
		if *a.FinalMarks != a.DraftMarks {
			overridden++
		}
	}
	s.audit(c, "marking.finalize", d.ID, fmt.Sprintf("Finalized %s/%s for %s (%d of %d marks changed from the draft)",
		formatMarks(total), formatMarks(d.MaxTotal), st.FullName(), overridden, len(d.Answers)), "")
	respondDraft(c, http.StatusOK, d)
}

// finalizedSubmission applies a finalized draft to the paper's submission.
// Scheme question n is the assessment's question n, so the scheme must have
// the same number of questions with the same marks — otherwise the recorded
// score could not equal what the teacher finalized, and nothing is written.
func (s *Server) finalizedSubmission(scheme domain.MarkingScheme, d domain.MarkingDraft) (domain.Submission, string) {
	a, ok := s.store.AssessmentByID(scheme.AssessmentID)
	if !ok {
		return domain.Submission{}, "The assessment this draft marks no longer exists"
	}
	sub, ok := s.store.SubmissionFor(a.ID, d.StudentID)
	if !ok || sub.ID != d.SubmissionID {
		return domain.Submission{}, "The paper this draft marks has been replaced; draft it again"
	}
	if len(d.Answers) != len(a.Questions) {
		return domain.Submission{}, fmt.Sprintf(
			"The scheme has %d questions but the assessment has %d, so the marks cannot be recorded against it",
			len(d.Answers), len(a.Questions))
	}
	marks := map[string]float64{}
	for k, v := range sub.TeacherMarks {
		marks[k] = v
	}
	for _, ans := range d.Answers {
		n := ans.QuestionNumber
		if n < 1 || n > len(a.Questions) {
			return domain.Submission{}, fmt.Sprintf("Scheme question %d has no matching assessment question", n)
		}
		q := a.Questions[n-1]
		if q.Marks != ans.TotalMarks {
			return domain.Submission{}, fmt.Sprintf(
				"Question %d is worth %s in the scheme but %s in the assessment, so the mark cannot be recorded",
				n, formatMarks(ans.TotalMarks), formatMarks(q.Marks))
		}
		marks[q.ID] = *ans.FinalMarks
	}
	sub.TeacherMarks = marks
	sub.MarkingSchemeID = scheme.ID
	sub.MarkingSchemeVersion = scheme.Version
	sub.Earned = marking.ComputeEarned(a.Questions, sub.Answers, sub.TeacherMarks)
	return sub, ""
}

func (s *Server) getMarkingDraft(c *gin.Context) {
	d, ok := s.store.MarkingDraftByID(c.Param("id"))
	if !ok || !teacherCoversClass(currentUser(c), d.ClassID) {
		fail(c, http.StatusNotFound, "Draft not found")
		return
	}
	respondDraft(c, http.StatusOK, d)
}
