package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
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
	SchemeID     string `json:"schemeId"`
	SubmissionID string `json:"submissionId"`
	StudentID    string `json:"studentId"`
	// Exactly one source: confirmed OCR readings (read from the teacher's
	// own ocr_jobs records, never from this body), or answers typed by the
	// teacher — the manual route when there is no usable photo.
	OcrJobIDs []string           `json:"ocrJobIds"`
	Answers   []draftAnswerInput `json:"answers"`
}

// draftResponse adds the flag every client must respect.
type draftResponse struct {
	domain.MarkingDraft
	Final bool `json:"final"`
}

func respondDraft(c *gin.Context, status int, d domain.MarkingDraft) {
	c.JSON(status, draftResponse{MarkingDraft: d, Final: false})
}

func (s *Server) createMarkingDraft(c *gin.Context) {
	u := currentUser(c)
	var body createDraftRequest
	if !bind(c, &body) {
		return
	}
	if body.SchemeID == "" || body.SubmissionID == "" || body.StudentID == "" {
		fail(c, http.StatusBadRequest, "schemeId, submissionId and studentId are required")
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
	kind, msg := s.checkDraftSubmission(scheme, body.SubmissionID, st.ID)
	if msg != "" {
		fail(c, http.StatusNotFound, msg)
		return
	}

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
// kind, or a message saying what is wrong.
func (s *Server) checkDraftSubmission(scheme domain.MarkingScheme, submissionID, studentID string) (string, string) {
	if scheme.AssessmentID != "" {
		sub, ok := s.store.SubmissionFor(scheme.AssessmentID, studentID)
		if !ok || sub.ID != submissionID {
			return "", "No such submission from this student for the scheme's assessment"
		}
		return domain.DraftTargetAssessment, ""
	}
	rec, ok := s.store.RecordByID(domain.RecordAssignmentSubmissions, submissionID)
	if !ok {
		return "", "No such submission from this student for the scheme's assignment"
	}
	var data struct {
		AssignmentID string `json:"assignmentId"`
		StudentID    string `json:"studentId"`
	}
	if json.Unmarshal(rec.Data, &data) != nil || data.AssignmentID != scheme.AssignmentID || data.StudentID != studentID {
		return "", "No such submission from this student for the scheme's assignment"
	}
	return domain.DraftTargetAssignment, ""
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

// listMarkingDrafts returns a paper's drafts, newest last.
func (s *Server) listMarkingDrafts(c *gin.Context) {
	u := currentUser(c)
	submissionID := c.Query("submissionId")
	if submissionID == "" {
		fail(c, http.StatusBadRequest, "submissionId is required")
		return
	}
	out := []draftResponse{}
	for _, d := range s.store.MarkingDraftsForSubmission(submissionID) {
		if teacherCoversClass(u, d.ClassID) {
			out = append(out, draftResponse{MarkingDraft: d})
		}
	}
	sendJSON(c, out)
}

func (s *Server) getMarkingDraft(c *gin.Context) {
	d, ok := s.store.MarkingDraftByID(c.Param("id"))
	if !ok || !teacherCoversClass(currentUser(c), d.ClassID) {
		fail(c, http.StatusNotFound, "Draft not found")
		return
	}
	respondDraft(c, http.StatusOK, d)
}
