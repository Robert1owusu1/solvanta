package httpapi

import (
	"net/http"
	"sort"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// =============================================================================
// Marking Scheme API — Phase 2
// =============================================================================

// createMarkingSchemeRequest is the payload for creating a marking scheme.
type createMarkingSchemeRequest struct {
	AssessmentID string                  `json:"assessmentId,omitempty"`
	AssignmentID string                  `json:"assignmentId,omitempty"`
	Questions    []domain.SchemeQuestion `json:"questions"`
}

// updateMarkingSchemeRequest is the payload for updating a marking scheme.
type updateMarkingSchemeRequest struct {
	Questions []domain.SchemeQuestion `json:"questions"`
}

// schemeQuestionsMatch reports whether two question lists are equivalent for
// GRADING purposes — i.e. no field that could affect an existing grade differs.
//
// LikelyCause is a teacher-facing explanatory note: it is never matched against
// student work and never contributes marks, so it is deliberately excluded
// here. This is what lets a notes-only edit stay on the same version.
func schemeQuestionsMatch(a, b []domain.SchemeQuestion) bool {
	return schemeQuestionsEqual(a, b, false)
}

// schemeQuestionsIdentical reports exact equality including notes. Used only
// to decide whether a PUT is a genuine no-op worth skipping entirely — a
// notes-only edit must still be persisted, just without bumping the version.
func schemeQuestionsIdentical(a, b []domain.SchemeQuestion) bool {
	return schemeQuestionsEqual(a, b, true)
}

// schemeQuestionsEqual compares two question lists by CONTENT only, optionally
// also comparing the grade-irrelevant misconception note (LikelyCause).
//
// Row IDs are deliberately never compared. They are server-owned identity
// (re-minted on every save), not content: a client holding slightly stale ids
// after a concurrent edit must not be read as "the scheme changed", which
// would otherwise fork a pointless new version while submissions exist.
func schemeQuestionsEqual(a, b []domain.SchemeQuestion, includeNotes bool) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].QuestionNumber != b[i].QuestionNumber ||
			a[i].TotalMarks != b[i].TotalMarks {
			return false
		}
		// Compare mark breakdown (content: what is marked and how much)
		if len(a[i].MarkBreakdown) != len(b[i].MarkBreakdown) {
			return false
		}
		for j := range a[i].MarkBreakdown {
			if a[i].MarkBreakdown[j].Type != b[i].MarkBreakdown[j].Type ||
				a[i].MarkBreakdown[j].Criteria != b[i].MarkBreakdown[j].Criteria ||
				a[i].MarkBreakdown[j].Marks != b[i].MarkBreakdown[j].Marks {
				return false
			}
		}
		// Compare accepted answers (content: what matches, and its marks)
		if len(a[i].AcceptedAnswers) != len(b[i].AcceptedAnswers) {
			return false
		}
		for j := range a[i].AcceptedAnswers {
			if a[i].AcceptedAnswers[j].AnswerText != b[i].AcceptedAnswers[j].AnswerText ||
				a[i].AcceptedAnswers[j].NormalizedForm != b[i].AcceptedAnswers[j].NormalizedForm ||
				a[i].AcceptedAnswers[j].MarksAwarded != b[i].AcceptedAnswers[j].MarksAwarded ||
				a[i].AcceptedAnswers[j].IsPrimary != b[i].AcceptedAnswers[j].IsPrimary {
				return false
			}
		}
		// Compare misconceptions. The wrong-answer pattern (matched against
		// student work) and its partial marks can change a grade, so they
		// always count. LikelyCause is a note and is compared only when
		// [includeNotes] is set.
		if len(a[i].Misconceptions) != len(b[i].Misconceptions) {
			return false
		}
		for j := range a[i].Misconceptions {
			if a[i].Misconceptions[j].WrongAnswerPattern != b[i].Misconceptions[j].WrongAnswerPattern ||
				a[i].Misconceptions[j].MarksAwarded != b[i].Misconceptions[j].MarksAwarded {
				return false
			}
			if includeNotes &&
				a[i].Misconceptions[j].LikelyCause != b[i].Misconceptions[j].LikelyCause {
				return false
			}
		}
	}
	return true
}

// createMarkingScheme creates a new marking scheme for an assessment or assignment.
// Role gates: follows the same rules as the parent type (admin-only for exam types).
func (s *Server) createMarkingScheme(c *gin.Context) {
	u := currentUser(c)

	var body createMarkingSchemeRequest
	if !bind(c, &body) {
		return
	}

	// Exactly one of assessment_id or assignment_id must be provided
	hasAssessment := body.AssessmentID != ""
	hasAssignment := body.AssignmentID != ""
	if hasAssessment == hasAssignment {
		fail(c, http.StatusBadRequest, "Exactly one of assessmentId or assignmentId must be provided")
		return
	}

	if len(body.Questions) == 0 {
		fail(c, http.StatusBadRequest, "At least one question is required")
		return
	}

	// Validate target exists and user has permission
	var assessment *domain.Assessment
	var assignment *domain.Assignment
	if hasAssessment {
		a, ok := s.store.AssessmentByID(body.AssessmentID)
		if !ok {
			fail(c, http.StatusNotFound, "Assessment not found")
			return
		}
		assessment = &a
		if !canCreateAssessmentType(u.Role, a.Type) {
			fail(c, http.StatusForbidden,
				"Only school admins and headteachers can create marking schemes for "+a.Type+" assessments")
			return
		}
		if !u.IsSchoolStaff() && !s.viewsClass(u, a.ClassID) {
			fail(c, http.StatusForbidden, "You may only create schemes for your own class")
			return
		}
	} else {
		a, ok := s.store.AssignmentByID(body.AssignmentID)
		if !ok {
			fail(c, http.StatusNotFound, "Assignment not found")
			return
		}
		assignment = &a
		if !u.IsSchoolStaff() {
			fail(c, http.StatusForbidden, "Only teachers and school leaders can create assignment marking schemes")
			return
		}
		if !s.viewsClass(u, a.ClassID) {
			fail(c, http.StatusForbidden, "You may only create schemes for your own class")
			return
		}
	}

	// Validate questions: question numbers must be sequential starting at 1
	for i, q := range body.Questions {
		if q.QuestionNumber != i+1 {
			fail(c, http.StatusBadRequest, "Question numbers must be sequential starting at 1")
			return
		}
		if q.TotalMarks <= 0 {
			fail(c, http.StatusBadRequest, "Total marks must be positive")
			return
		}
		// Validate mark breakdown sum equals total_marks
		var breakdownSum float64
		for _, step := range q.MarkBreakdown {
			breakdownSum += step.Marks
		}
		if abs(breakdownSum-q.TotalMarks) > 0.01 {
			fail(c, http.StatusBadRequest, "Mark breakdown sum must equal total_marks")
			return
		}
		// Ensure exactly one primary accepted answer per question
		primaryCount := 0
		for _, aa := range q.AcceptedAnswers {
			if aa.IsPrimary {
				primaryCount++
			}
		}
		if primaryCount != 1 {
			fail(c, http.StatusBadRequest, "Exactly one accepted answer must be marked primary per question")
			return
		}
	}

	// Get next version number
	nextVersion := s.store.LatestSchemeVersion(body.AssessmentID, body.AssignmentID) + 1

	// Generate ID
	schemeID := newID("MS")

	// Build the scheme with server-set fields
	scheme := domain.MarkingScheme{
		ID:             schemeID,
		AssessmentID:   body.AssessmentID,
		AssignmentID:   body.AssignmentID,
		Version:        nextVersion,
		ParentSchemeID: "",
		CreatedBy:      firstNonEmpty(u.ID, u.Name),
		CreatedAt:      now(),
		Questions:      body.Questions,
	}

	// Server-owned fields: fresh row identities plus back-references.
	//
	// IDs are always re-minted here rather than trusted from the client.
	// Client ids are only unique within one scheme (answers are numbered
	// 1,2,3… / 1001,1002…), while scheme_questions.id and the nested
	// BIGSERIAL ids are GLOBAL primary keys that both stores upsert on —
	// reusing them would overwrite and re-parent another scheme's rows.
	for i := range scheme.Questions {
		scheme.Questions[i].ID = newQuestionID()
		scheme.Questions[i].SchemeID = scheme.ID
		scheme.Questions[i].CreatedAt = now()
		for j := range scheme.Questions[i].MarkBreakdown {
			if scheme.Questions[i].MarkBreakdown[j].ID == "" {
				scheme.Questions[i].MarkBreakdown[j].ID = "step-" + itoa(j+1)
			}
		}
		for j := range scheme.Questions[i].AcceptedAnswers {
			scheme.Questions[i].AcceptedAnswers[j].ID = newIntID()
			scheme.Questions[i].AcceptedAnswers[j].SchemeQuestionID = scheme.Questions[i].ID
			scheme.Questions[i].AcceptedAnswers[j].CreatedAt = now()
		}
		for j := range scheme.Questions[i].Misconceptions {
			scheme.Questions[i].Misconceptions[j].ID = newIntID()
			scheme.Questions[i].Misconceptions[j].SchemeQuestionID = scheme.Questions[i].ID
			scheme.Questions[i].Misconceptions[j].CreatedAt = now()
		}
	}

	if writeFailed(c, s.store.SaveMarkingScheme(scheme)) {
		return
	}

	// Save questions
	for _, q := range scheme.Questions {
		if writeFailed(c, s.store.SaveSchemeQuestion(q)) {
			return
		}
		for _, aa := range q.AcceptedAnswers {
			if writeFailed(c, s.store.SaveAcceptedAnswer(aa)) {
				return
			}
		}
		for _, msc := range q.Misconceptions {
			if writeFailed(c, s.store.SaveMisconception(msc)) {
				return
			}
		}
	}

	s.audit(c, "marking_scheme.create", scheme.ID,
		"Created marking scheme v"+itoa(nextVersion)+" for "+targetLabel(assessment, assignment), "")
	sendCreated(c, scheme)
}

// getMarkingScheme returns a marking scheme with all its questions and nested data.
func (s *Server) getMarkingScheme(c *gin.Context) {
	id := c.Param("id")
	scheme, ok := s.store.MarkingSchemeByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Marking scheme not found")
		return
	}
	u := currentUser(c)

	// Check access
	if !u.IsSchoolStaff() {
		// Students/parents can only see schemes for their class
		var classID string
		if scheme.AssessmentID != "" {
			if a, ok := s.store.AssessmentByID(scheme.AssessmentID); ok {
				classID = a.ClassID
			}
		} else if scheme.AssignmentID != "" {
			if a, ok := s.store.AssignmentByID(scheme.AssignmentID); ok {
				classID = a.ClassID
			}
		}
		if !s.viewsClass(u, classID) {
			fail(c, http.StatusForbidden, "You may only view schemes for your own class")
			return
		}
	}

	// Load questions with nested data
	scheme.Questions = s.store.SchemeQuestions(scheme.ID)
	sendJSON(c, scheme)
}

// updateMarkingScheme updates a marking scheme.
// VERSIONING RULE: If the scheme has submissions marked against it, create a NEW version
// (new ID, version = existing.version + 1, parent_scheme_id = existing.id).
// If NO submissions exist, update in place.
func (s *Server) updateMarkingScheme(c *gin.Context) {
	id := c.Param("id")
	u := currentUser(c)

	existing, ok := s.store.MarkingSchemeByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Marking scheme not found")
		return
	}

	// Check permission (same as create)
	if existing.AssessmentID != "" {
		a, _ := s.store.AssessmentByID(existing.AssessmentID)
		if !canCreateAssessmentType(u.Role, a.Type) {
			fail(c, http.StatusForbidden, "Only school admins and headteachers can edit this scheme")
			return
		}
		if !u.IsSchoolStaff() && !s.viewsClass(u, a.ClassID) {
			fail(c, http.StatusForbidden, "You may only edit schemes for your own class")
			return
		}
	} else if existing.AssignmentID != "" {
		a, _ := s.store.AssignmentByID(existing.AssignmentID)
		if !u.IsSchoolStaff() {
			fail(c, http.StatusForbidden, "Only teachers and school leaders can edit assignment schemes")
			return
		}
		if !s.viewsClass(u, a.ClassID) {
			fail(c, http.StatusForbidden, "You may only edit schemes for your own class")
			return
		}
	}

	var body updateMarkingSchemeRequest
	if !bind(c, &body) {
		return
	}

	if len(body.Questions) == 0 {
		fail(c, http.StatusBadRequest, "At least one question is required")
		return
	}

	// Validate questions (same as create)
	for i, q := range body.Questions {
		if q.QuestionNumber != i+1 {
			fail(c, http.StatusBadRequest, "Question numbers must be sequential starting at 1")
			return
		}
		if q.TotalMarks <= 0 {
			fail(c, http.StatusBadRequest, "Total marks must be positive")
			return
		}
		var breakdownSum float64
		for _, step := range q.MarkBreakdown {
			breakdownSum += step.Marks
		}
		if abs(breakdownSum-q.TotalMarks) > 0.01 {
			fail(c, http.StatusBadRequest, "Mark breakdown sum must equal total_marks")
			return
		}
		primaryCount := 0
		for _, aa := range q.AcceptedAnswers {
			if aa.IsPrimary {
				primaryCount++
			}
		}
		if primaryCount != 1 {
			fail(c, http.StatusBadRequest, "Exactly one accepted answer must be marked primary per question")
			return
		}
	}

	// Decide what kind of edit this is. Three distinct outcomes:
	//
	//   1. Byte-identical (notes included) → no-op, return existing untouched.
	//   2. Grade-relevant fields changed AND submissions exist → NEW version.
	//   3. Everything else — including a notes-only edit with submissions
	//      present — → update in place.
	existingQuestions := s.store.SchemeQuestions(existing.ID)
	if schemeQuestionsIdentical(existingQuestions, body.Questions) {
		// No changes — return existing
		sendJSON(c, existing)
		return
	}

	gradeChanged := !schemeQuestionsMatch(existingQuestions, body.Questions)

	// Check if there are submissions marked against this scheme
	submissions := s.store.SubmissionsByScheme(existing.ID)

	var schemeToSave domain.MarkingScheme

	if gradeChanged && len(submissions) > 0 {
		// SUBMISSIONS EXIST → CREATE NEW VERSION
		newVersion := existing.Version + 1
		schemeToSave = domain.MarkingScheme{
			ID:             newID("MS"),
			AssessmentID:   existing.AssessmentID,
			AssignmentID:   existing.AssignmentID,
			Version:        newVersion,
			ParentSchemeID: existing.ID,
			CreatedBy:      firstNonEmpty(u.ID, u.Name),
			CreatedAt:      now(),
			Questions:      body.Questions,
		}
		s.audit(c, "marking_scheme.update.new_version", schemeToSave.ID,
			"Created new version v"+itoa(newVersion)+" of marking scheme (v"+itoa(existing.Version)+" had "+itoa(len(submissions))+" submissions)",
			"")
	} else {
		// UPDATE IN PLACE — either there are no submissions, or the only
		// edit was grade-irrelevant (a misconception note). Neither can
		// invalidate a grade that was already recorded against this version.
		schemeToSave = existing
		schemeToSave.Questions = body.Questions
		reason := "no submissions"
		if len(submissions) > 0 {
			reason = "notes-only change, no grade impact (" +
				itoa(len(submissions)) + " submissions unaffected)"
		}
		s.audit(c, "marking_scheme.update.in_place", existing.ID,
			"Updated marking scheme v"+itoa(existing.Version)+" in place ("+reason+")",
			"")
	}

	// Server-owned fields on every save branch: fresh row identities, parent
	// scheme ID, back-references and timestamps.
	//
	// Re-minting IDs here is what protects the version chain. The new-version
	// branch receives the client's questions carrying v1's original row ids;
	// both stores upsert ON CONFLICT (id), so writing them as-is would
	// overwrite v1's question/answer/misconception rows in place and silently
	// re-point them at v2 — leaving the version that submissions are graded
	// against empty. Fresh ids mean v2 gets its own rows and v1 stays intact.
	// (The in-place branch deletes the old rows first, so re-minting is safe
	// there too — and it also stops one scheme's client-side ids from
	// colliding with another scheme's.)
	schemeToSave.CreatedAt = now()
	for i := range schemeToSave.Questions {
		schemeToSave.Questions[i].ID = newQuestionID()
		schemeToSave.Questions[i].SchemeID = schemeToSave.ID
		schemeToSave.Questions[i].CreatedAt = now()
		for j := range schemeToSave.Questions[i].MarkBreakdown {
			if schemeToSave.Questions[i].MarkBreakdown[j].ID == "" {
				schemeToSave.Questions[i].MarkBreakdown[j].ID = "step-" + itoa(j+1)
			}
		}
		for j := range schemeToSave.Questions[i].AcceptedAnswers {
			schemeToSave.Questions[i].AcceptedAnswers[j].ID = newIntID()
			schemeToSave.Questions[i].AcceptedAnswers[j].SchemeQuestionID = schemeToSave.Questions[i].ID
			schemeToSave.Questions[i].AcceptedAnswers[j].CreatedAt = now()
		}
		for j := range schemeToSave.Questions[i].Misconceptions {
			schemeToSave.Questions[i].Misconceptions[j].ID = newIntID()
			schemeToSave.Questions[i].Misconceptions[j].SchemeQuestionID = schemeToSave.Questions[i].ID
			schemeToSave.Questions[i].Misconceptions[j].CreatedAt = now()
		}
	}

	if writeFailed(c, s.store.SaveMarkingScheme(schemeToSave)) {
		return
	}

	// Save questions (delete old if in-place update, or insert new for new version)
	if schemeToSave.ID == existing.ID {
		// In-place update: replace all questions
		for _, q := range existingQuestions {
			s.store.DeleteSchemeQuestion(q.ID)
			for _, aa := range q.AcceptedAnswers {
				s.store.DeleteAcceptedAnswer(aa.ID)
			}
			for _, msc := range q.Misconceptions {
				s.store.DeleteMisconception(msc.ID)
			}
		}
	}

	for _, q := range schemeToSave.Questions {
		if writeFailed(c, s.store.SaveSchemeQuestion(q)) {
			return
		}
		for _, aa := range q.AcceptedAnswers {
			if writeFailed(c, s.store.SaveAcceptedAnswer(aa)) {
				return
			}
		}
		for _, msc := range q.Misconceptions {
			if writeFailed(c, s.store.SaveMisconception(msc)) {
				return
			}
		}
	}

	sendJSON(c, schemeToSave)
}

// listMarkingSchemes returns all marking schemes (scoped by role).
func (s *Server) listMarkingSchemes(c *gin.Context) {
	u := currentUser(c)
	var schemes []domain.MarkingScheme

	if u.IsSchoolStaff() {
		schemes = s.store.MarkingSchemes()
	} else {
		// Students/parents only see schemes for their class
		var classID string
		if u.Role == domain.RoleStudent {
			if st, ok := s.store.StudentByID(stringToStudentID(u.ID)); ok {
				classID = st.ClassID
			}
		} else if u.Role == domain.RoleParent {
			for _, sid := range u.StudentIDs {
				if st, ok := s.store.StudentByID(sid); ok {
					classID = st.ClassID
					break
				}
			}
		}
		for _, ms := range s.store.MarkingSchemes() {
			var msClassID string
			if ms.AssessmentID != "" {
				if a, ok := s.store.AssessmentByID(ms.AssessmentID); ok {
					msClassID = a.ClassID
				}
			} else if ms.AssignmentID != "" {
				if a, ok := s.store.AssignmentByID(ms.AssignmentID); ok {
					msClassID = a.ClassID
				}
			}
			if msClassID == classID {
				schemes = append(schemes, ms)
			}
		}
	}

	// Sort: newest first
	sort.Slice(schemes, func(i, j int) bool { return schemes[i].CreatedAt > schemes[j].CreatedAt })

	sendJSON(c, schemes)
}

// deleteMarkingScheme deletes a marking scheme (only if no submissions).
func (s *Server) deleteMarkingScheme(c *gin.Context) {
	id := c.Param("id")
	u := currentUser(c)

	existing, ok := s.store.MarkingSchemeByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Marking scheme not found")
		return
	}

	// Check permission
	if existing.AssessmentID != "" {
		a, _ := s.store.AssessmentByID(existing.AssessmentID)
		if !canCreateAssessmentType(u.Role, a.Type) {
			fail(c, http.StatusForbidden, "Only school admins and headteachers can delete this scheme")
			return
		}
	} else if existing.AssignmentID != "" {
		_, _ = s.store.AssignmentByID(existing.AssignmentID)
		if !u.IsSchoolStaff() {
			fail(c, http.StatusForbidden, "Only teachers and school leaders can delete assignment schemes")
			return
		}
	}

	// Prevent deletion if submissions exist
	submissions := s.store.SubmissionsByScheme(existing.ID)
	if len(submissions) > 0 {
		fail(c, http.StatusConflict, "Cannot delete marking scheme with existing submissions (versioning required)")
		return
	}

	if writeFailed(c, s.store.DeleteMarkingScheme(existing.ID)) {
		return
	}

	// Delete associated questions/answers/misconceptions
	questions := s.store.SchemeQuestions(existing.ID)
	for _, q := range questions {
		for _, aa := range q.AcceptedAnswers {
			s.store.DeleteAcceptedAnswer(aa.ID)
		}
		for _, msc := range q.Misconceptions {
			s.store.DeleteMisconception(msc.ID)
		}
		s.store.DeleteSchemeQuestion(q.ID)
	}

	s.audit(c, "marking_scheme.delete", existing.ID, "Deleted marking scheme v"+itoa(existing.Version), "")
	c.Status(http.StatusNoContent)
}

// --- helpers ---

func targetLabel(a *domain.Assessment, asg *domain.Assignment) string {
	if a != nil {
		return "assessment " + a.Title
	}
	return "assignment " + asg.Title
}

// listMarkingSchemesForAssessment returns all marking schemes for a specific assessment.
func (s *Server) listMarkingSchemesForAssessment(c *gin.Context) {
	assessmentID := c.Param("id")
	u := currentUser(c)

	// Verify assessment exists and user has access
	a, ok := s.store.AssessmentByID(assessmentID)
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	if !u.IsSchoolStaff() && !s.viewsClass(u, a.ClassID) {
		fail(c, http.StatusForbidden, "You may only view schemes for your own class")
		return
	}

	schemes := s.store.MarkingSchemesByAssessment(assessmentID)

	// Load questions for each scheme
	for i := range schemes {
		schemes[i].Questions = s.store.SchemeQuestions(schemes[i].ID)
	}

	// Sort: newest version first
	sort.Slice(schemes, func(i, j int) bool { return schemes[i].Version > schemes[j].Version })

	sendJSON(c, schemes)
}

// listMarkingSchemesForAssignment returns all marking schemes for a specific assignment.
func (s *Server) listMarkingSchemesForAssignment(c *gin.Context) {
	assignmentID := c.Param("id")
	u := currentUser(c)

	// Verify assignment exists and user has access
	a, ok := s.store.AssignmentByID(assignmentID)
	if !ok {
		fail(c, http.StatusNotFound, "Assignment not found")
		return
	}
	if !u.IsSchoolStaff() && !s.viewsClass(u, a.ClassID) {
		fail(c, http.StatusForbidden, "You may only view schemes for your own class")
		return
	}

	schemes := s.store.MarkingSchemesByAssignment(assignmentID)

	// Load questions for each scheme
	for i := range schemes {
		schemes[i].Questions = s.store.SchemeQuestions(schemes[i].ID)
	}

	// Sort: newest version first
	sort.Slice(schemes, func(i, j int) bool { return schemes[i].Version > schemes[j].Version })

	sendJSON(c, schemes)
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}
