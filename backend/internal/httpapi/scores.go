package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// Manual score entry (feature: schools that mark on paper). A score is recorded
// directly against an assessment's class roster, with no answers and no
// question-by-question marking. RBAC is the same as marking: a teacher records
// for their own class only; school leaders for any class. The write is
// offline-first on the client, so the handlers are idempotent — replaying the
// same score (or the same bulk upload) lands the same row, never a second one.

// scoreInput is one manual score: the body of the single-entry endpoint and
// one element of the bulk endpoint's array.
type scoreInput struct {
	StudentID   string   `json:"studentId"`
	AdmissionNo string   `json:"admissionNo"`
	Score       *float64 `json:"score"`
	Absent      bool     `json:"absent"`
	Remark      string   `json:"remark"`
	// Override confirms a manual edit over a score already marked by AI. The
	// single endpoint reads it from the body; the bulk endpoint from the batch.
	Override bool `json:"override"`
}

// termFinished reports whether the assessment's date falls inside a term the
// school has already finished. A manual score may be edited only until then.
func (s *Server) termFinished(c *gin.Context, date string) bool {
	if date == "" {
		return false
	}
	for _, ft := range s.db(c).FinishedTerms(s.gradingSchool(c)) {
		if ft.Contains(date) {
			return true
		}
	}
	return false
}

// resolveRosterStudent finds the student a score row is for, matching on
// studentId first and admissionNo second — never on name — and only within the
// assessment's own class. ok is false with a reason when no unambiguous match
// sits in the class.
func (s *Server) resolveRosterStudent(c *gin.Context, classID string, in scoreInput) (domain.Student, string, bool) {
	if in.StudentID != "" {
		st, ok := s.db(c).StudentByID(in.StudentID)
		if !ok {
			return domain.Student{}, "unknown studentId", false
		}
		if st.ClassID != classID {
			return domain.Student{}, "student is not in this class", false
		}
		return st, "", true
	}
	if in.AdmissionNo != "" {
		var match domain.Student
		found := 0
		for _, st := range s.db(c).Students() {
			if st.ClassID == classID && st.AdmissionNo != "" && st.AdmissionNo == in.AdmissionNo {
				match = st
				found++
			}
		}
		switch found {
		case 0:
			return domain.Student{}, "unknown admissionNo", false
		case 1:
			return match, "", true
		default:
			return domain.Student{}, "admissionNo matches more than one student", false
		}
	}
	return domain.Student{}, "a row needs a studentId or an admissionNo", false
}

// validateScore checks the range (0 ≤ score ≤ effective total; half marks
// allowed) for a row that is not marked absent. It returns a client message, or
// "" when the row is valid.
func validateScore(a domain.Assessment, in scoreInput) string {
	if in.Absent {
		return ""
	}
	if in.Score == nil {
		return "score is required unless the pupil is absent"
	}
	if *in.Score < 0 {
		return "score cannot be negative"
	}
	if *in.Score > a.EffectiveTotal() {
		return "score is above the maximum of " + formatMarks(a.EffectiveTotal())
	}
	return ""
}

// applyManualScore writes (or replaces) one manual submission and audits the
// change with the old and new values. It assumes RBAC, the term-lock and
// validation have already passed. requiresOverride is returned true, without
// writing, when the existing score was marked by AI and the caller did not
// confirm an override.
func (s *Server) applyManualScore(c *gin.Context, a domain.Assessment, st domain.Student, in scoreInput) (domain.Submission, bool, error) {
	prev, had := s.db(c).SubmissionFor(a.ID, st.ID)
	if had && prev.EffectiveSource() == domain.SourceAI && !in.Override {
		return domain.Submission{}, true, nil
	}

	earned := 0.0
	if !in.Absent && in.Score != nil {
		earned = *in.Score
	}
	id := newID("SUB")
	if had {
		id = prev.ID
	}
	sub := domain.Submission{
		ID:           id,
		AssessmentID: a.ID,
		StudentID:    st.ID,
		ClassID:      st.ClassID, // always the pupil's own class — analytics group on it
		Date:         firstNonEmpty(prev.Date, today()),
		Answers:      map[string]string{},
		TeacherMarks: map[string]float64{},
		Earned:       earned,
		Source:       domain.SourceManual,
		Remark:       in.Remark,
		Absent:       in.Absent,
	}
	if err := s.db(c).SaveSubmission(sub); err != nil {
		return domain.Submission{}, false, err
	}

	reason := ""
	if had && prev.EffectiveSource() == domain.SourceAI {
		reason = "override of AI-marked score"
	}
	s.audit(c, "score.manual", sub.ID,
		"Manual score for "+st.FullName()+" on "+a.Title+": "+describeScore(a, prev, had)+" → "+describeScore(a, sub, true),
		reason)
	return sub, false, nil
}

// describeScore renders a submission's score for the audit trail: "absent",
// "none" (no prior row) or "4.5/10".
func describeScore(a domain.Assessment, sub domain.Submission, present bool) string {
	if !present {
		return "none"
	}
	if sub.Absent {
		return "absent"
	}
	return formatMarks(sub.Earned) + "/" + formatMarks(a.EffectiveTotal())
}

// putScore records a single manual score against an assessment's roster.
// PUT /api/assessments/:id/scores/:studentId
func (s *Server) putScore(c *gin.Context) {
	a, ok := s.db(c).AssessmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	var in scoreInput
	if !bind(c, &in) {
		return
	}
	in.StudentID = c.Param("studentId") // the path wins over any body studentId

	st, reason, ok := s.resolveRosterStudent(c, a.ClassID, in)
	if !ok {
		fail(c, http.StatusNotFound, reason)
		return
	}
	if !teacherCoversClass(currentUser(c), st.ClassID) {
		fail(c, http.StatusForbidden, "You may only record scores for your own class")
		return
	}
	if s.termFinished(c, a.Date) {
		fail(c, http.StatusConflict, "This term is finished; its scores can no longer be edited")
		return
	}
	if msg := validateScore(a, in); msg != "" {
		fail(c, http.StatusBadRequest, msg)
		return
	}
	sub, needsOverride, err := s.applyManualScore(c, a, st, in)
	if err != nil {
		writeFailed(c, err)
		return
	}
	if needsOverride {
		c.JSON(http.StatusConflict, gin.H{
			"error":            "This score was marked by AI. Confirm the override to replace it.",
			"requiresOverride": true,
		})
		return
	}
	sendJSON(c, sub)
}

// bulkScoreResult is one row's outcome in the bulk response.
type bulkScoreResult struct {
	Index       int    `json:"index"`
	StudentID   string `json:"studentId,omitempty"`
	AdmissionNo string `json:"admissionNo,omitempty"`
	Status      string `json:"status"` // ok | error
	Error       string `json:"error,omitempty"`
}

// bulkScores records many manual scores in one atomic batch.
// POST /api/assessments/:id/scores/bulk
//
// The body is an array of score rows. Every row is validated first; if any row
// is invalid nothing is written and the per-row results come back with 422, so
// a bad upload never half-applies. When every row is valid all are saved and
// the response is 200. Replaying the same batch lands the same rows (the save
// upserts on assessment+student), so an offline client's retry is a no-op.
func (s *Server) bulkScores(c *gin.Context) {
	a, ok := s.db(c).AssessmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	// Accept either a bare array or {"override":true,"scores":[...]} so an
	// override can cover the whole batch.
	var rows []scoreInput
	batchOverride := false
	if !bindBulkScores(c, &rows, &batchOverride) {
		return // bind already answered
	}
	if !teacherCoversClass(currentUser(c), a.ClassID) {
		fail(c, http.StatusForbidden, "You may only record scores for your own class")
		return
	}
	if s.termFinished(c, a.Date) {
		fail(c, http.StatusConflict, "This term is finished; its scores can no longer be edited")
		return
	}

	results := make([]bulkScoreResult, len(rows))
	resolved := make([]domain.Student, len(rows))
	anyError := false
	seen := map[string]int{} // studentId → first row, to flag duplicates

	for i, in := range rows {
		res := bulkScoreResult{Index: i, StudentID: in.StudentID, AdmissionNo: in.AdmissionNo, Status: "ok"}
		st, reason, okRow := s.resolveRosterStudent(c, a.ClassID, in)
		if !okRow {
			res.Status, res.Error = "error", reason
			anyError = true
			results[i] = res
			continue
		}
		if first, dup := seen[st.ID]; dup {
			res.Status, res.Error = "error", "duplicate row for the same student (first seen at row "+itoa(first)+")"
			anyError = true
			results[i] = res
			continue
		}
		seen[st.ID] = i
		if msg := validateScore(a, in); msg != "" {
			res.Status, res.Error = "error", msg
			anyError = true
			results[i] = res
			continue
		}
		// An AI-marked score needs the override confirmed up front, so the whole
		// batch is rejected before anything is written rather than half-applied.
		if prev, had := s.db(c).SubmissionFor(a.ID, st.ID); had &&
			prev.EffectiveSource() == domain.SourceAI && !(in.Override || batchOverride) {
			res.Status, res.Error = "error", "this score was marked by AI; confirm the override to replace it"
			anyError = true
			results[i] = res
			continue
		}
		resolved[i] = st
		res.StudentID = st.ID
		results[i] = res
	}

	if anyError {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"results": results, "saved": false})
		return
	}

	// Every row has passed validation and any override check: apply them all.
	for i, in := range rows {
		in.Override = in.Override || batchOverride
		if _, _, err := s.applyManualScore(c, a, resolved[i], in); err != nil {
			writeFailed(c, err)
			return
		}
	}
	sendJSON(c, gin.H{"results": results, "saved": true})
}

// bindBulkScores decodes the bulk body, which may be a bare array or an object
// wrapping the array with a batch-wide override. It returns false, having
// already written an error, when the body is neither.
func bindBulkScores(c *gin.Context, rows *[]scoreInput, override *bool) bool {
	data, err := c.GetRawData()
	if err != nil {
		fail(c, http.StatusBadRequest, "Invalid request body")
		return false
	}
	// A bare array is the common case.
	if err := json.Unmarshal(data, rows); err == nil {
		return true
	}
	var wrapper struct {
		Override bool         `json:"override"`
		Scores   []scoreInput `json:"scores"`
	}
	if err := json.Unmarshal(data, &wrapper); err != nil {
		fail(c, http.StatusBadRequest, "Invalid request body: expected an array of scores")
		return false
	}
	*rows = wrapper.Scores
	*override = wrapper.Override
	return true
}
