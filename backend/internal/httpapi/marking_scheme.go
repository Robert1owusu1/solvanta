package httpapi

import (
	"math"
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

	// The URL names the target too; a body naming a different one must not
	// write a scheme somewhere the route didn't say.
	if pathID := c.Param("id"); pathID != "" && pathID != body.AssessmentID+body.AssignmentID {
		fail(c, http.StatusBadRequest, "Target in the body does not match the URL")
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
		if !canWriteSchemeFor(u, a.ClassID) {
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
		if !canWriteSchemeFor(u, a.ClassID) {
			fail(c, http.StatusForbidden, "You may only create schemes for your own class")
			return
		}
	}

	if msg := validateSchemeQuestions(body.Questions); msg != "" {
		fail(c, http.StatusBadRequest, msg)
		return
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

	// Save questions. A failure removes the scheme row too, so a half-written
	// scheme can never become the latest version and be marked against.
	if err := s.saveSchemeRows(scheme.Questions); err != nil {
		_ = s.store.DeleteMarkingScheme(scheme.ID)
		writeFailed(c, err)
		return
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

	// A scheme is the answer key: only the people who may write it read it.
	if classID, _ := s.schemeTarget(scheme); !canWriteSchemeFor(u, classID) {
		fail(c, http.StatusForbidden, "You may only view schemes for your own class")
		return
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
	if !s.canWriteScheme(c, u, existing, "edit") {
		return
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
	if msg := validateSchemeQuestions(body.Questions); msg != "" {
		fail(c, http.StatusBadRequest, msg)
		return
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

	// In-place update: the old rows must go first, because (scheme_id,
	// question_number) is unique and the replacements reuse the numbers.
	inPlace := schemeToSave.ID == existing.ID
	if inPlace {
		s.deleteSchemeRows(existingQuestions)
	}
	if err := s.saveSchemeRows(schemeToSave.Questions); err != nil {
		// saveSchemeRows has removed its partial writes; put the previous
		// questions back so a failed edit leaves the scheme as it was rather
		// than empty, or drop the new version that never got its rows.
		if inPlace {
			_ = s.saveSchemeRows(existingQuestions)
		} else {
			_ = s.store.DeleteMarkingScheme(schemeToSave.ID)
		}
		writeFailed(c, err)
		return
	}

	sendJSON(c, schemeToSave)
}

// listMarkingSchemes returns all marking schemes (scoped by role).
func (s *Server) listMarkingSchemes(c *gin.Context) {
	u := currentUser(c)
	schemes := []domain.MarkingScheme{}

	// Same rule as getMarkingScheme, per scheme: students and parents get an
	// empty list, a teacher only their own class's schemes.
	for _, ms := range s.store.MarkingSchemes() {
		if classID, _ := s.schemeTarget(ms); canWriteSchemeFor(u, classID) {
			schemes = append(schemes, ms)
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

	// Check permission (same as create)
	if !s.canWriteScheme(c, u, existing, "delete") {
		return
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

// canWriteSchemeFor is the class half of the scheme rule. School leaders (and
// the super admin) work on any class in the school; a teacher only on the class
// they teach. Everyone else — staff, parents, students — never: a scheme is the
// answer key, so this gates reads as well as writes. The exam-type half is
// canCreateAssessmentType, checked separately where an assessment is the target.
func canWriteSchemeFor(u domain.User, classID string) bool {
	switch u.Role {
	case domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher:
		return true
	case domain.RoleTeacher:
		return classID != "" && classID == u.ClassID
	}
	return false
}

// schemeTarget resolves the class a scheme is for, and the assessment type when
// it belongs to an assessment ("" for an assignment). A missing target gives
// an empty class, which only leaders pass.
func (s *Server) schemeTarget(ms domain.MarkingScheme) (classID, assessmentType string) {
	if ms.AssessmentID != "" {
		if a, ok := s.store.AssessmentByID(ms.AssessmentID); ok {
			return a.ClassID, a.Type
		}
	} else if ms.AssignmentID != "" {
		if a, ok := s.store.AssignmentByID(ms.AssignmentID); ok {
			return a.ClassID, ""
		}
	}
	return "", ""
}

// canWriteScheme applies the create rule to an existing scheme for an edit or
// delete, writing the 403 itself when it refuses.
func (s *Server) canWriteScheme(c *gin.Context, u domain.User, ms domain.MarkingScheme, verb string) bool {
	classID, typ := s.schemeTarget(ms)
	if typ != "" && !canCreateAssessmentType(u.Role, typ) {
		fail(c, http.StatusForbidden, "Only school admins and headteachers can "+verb+" this scheme")
		return false
	}
	if !canWriteSchemeFor(u, classID) {
		fail(c, http.StatusForbidden, "You may only "+verb+" schemes for your own class")
		return false
	}
	return true
}

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
	if !canWriteSchemeFor(u, a.ClassID) {
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
	if !canWriteSchemeFor(u, a.ClassID) {
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

// maxSchemeMarks is the largest value NUMERIC(6,2) holds.
const maxSchemeMarks = 9999.99

// cents converts a mark to whole hundredths, reporting false when it has more
// than two decimal places. The columns are NUMERIC(6,2) and the database checks
// the breakdown sum exactly, so a mark the column would round (3.333) has to be
// refused here as a 400 rather than surfacing as a failed write.
func cents(x float64) (int64, bool) {
	c := math.Round(x * 100)
	return int64(c), math.Abs(x*100-c) < 1e-6
}

// validateSchemeQuestions returns why a question list cannot be saved, or ""
// when it can. Shared by create and update so the two can never drift.
func validateSchemeQuestions(qs []domain.SchemeQuestion) string {
	inRange := func(x, max float64) bool {
		_, ok := cents(x)
		return ok && x >= 0 && x <= max
	}
	for i, q := range qs {
		if q.QuestionNumber != i+1 {
			return "Question numbers must be sequential starting at 1"
		}
		total, ok := cents(q.TotalMarks)
		if !ok || q.TotalMarks <= 0 || q.TotalMarks > maxSchemeMarks {
			return "Total marks must be positive, with at most two decimal places"
		}
		var sum int64
		for _, step := range q.MarkBreakdown {
			if !inRange(step.Marks, q.TotalMarks) {
				return "Each breakdown step must be between 0 and the question's total, with at most two decimal places"
			}
			c, _ := cents(step.Marks)
			sum += c
		}
		if sum != total {
			return "Mark breakdown sum must equal total_marks"
		}
		primaryCount := 0
		for _, aa := range q.AcceptedAnswers {
			if aa.IsPrimary {
				primaryCount++
			}
			if !inRange(aa.MarksAwarded, q.TotalMarks) {
				return "An accepted answer's marks must be between 0 and the question's total"
			}
		}
		if primaryCount != 1 {
			return "Exactly one accepted answer must be marked primary per question"
		}
		for _, msc := range q.Misconceptions {
			if !inRange(msc.MarksAwarded, q.TotalMarks) {
				return "A misconception's marks must be between 0 and the question's total"
			}
		}
	}
	return ""
}

// saveSchemeRows writes every question with its answers and misconceptions.
// When a write fails it removes what this call already wrote, so the store is
// never left holding part of a scheme, and returns the error.
func (s *Server) saveSchemeRows(qs []domain.SchemeQuestion) error {
	for i, q := range qs {
		if err := s.saveSchemeQuestion(q); err != nil {
			s.deleteSchemeRows(qs[:i+1])
			return err
		}
	}
	return nil
}

func (s *Server) saveSchemeQuestion(q domain.SchemeQuestion) error {
	if err := s.store.SaveSchemeQuestion(q); err != nil {
		return err
	}
	for _, aa := range q.AcceptedAnswers {
		if err := s.store.SaveAcceptedAnswer(aa); err != nil {
			return err
		}
	}
	for _, msc := range q.Misconceptions {
		if err := s.store.SaveMisconception(msc); err != nil {
			return err
		}
	}
	return nil
}

// deleteSchemeRows removes questions with their answers and misconceptions.
// Best effort: it runs on paths that are already reporting a failure, or after
// the replacement rows are safely in.
func (s *Server) deleteSchemeRows(qs []domain.SchemeQuestion) {
	for _, q := range qs {
		for _, aa := range q.AcceptedAnswers {
			_ = s.store.DeleteAcceptedAnswer(aa.ID)
		}
		for _, msc := range q.Misconceptions {
			_ = s.store.DeleteMisconception(msc.ID)
		}
		_ = s.store.DeleteSchemeQuestion(q.ID)
	}
}
