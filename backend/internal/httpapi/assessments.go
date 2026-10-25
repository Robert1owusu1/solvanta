package httpapi

import (
	"math"
	"net/http"
	"sort"
	"strconv"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/marking"
)

var validAssessmentTypes = map[string]bool{
	domain.TypeExercise: true, domain.TypeHomework: true, domain.TypeQuiz: true,
	domain.TypeClassTest: true, domain.TypeMidTerm: true, domain.TypeEndTerm: true,
	domain.TypeMock: true, domain.TypeDiagnostic: true, domain.TypeRemedial: true,
	domain.TypeVacation: true,
}

// adminOnlyAssessmentTypes are the exam-related types only school leaders may
// create (doc §16 policy): Mid-Term / End-of-Term / Mock examinations plus the
// formal Diagnostic / Remedial assessments. Teachers may still create quizzes,
// class tests, exercises, homework and vacation work.
var adminOnlyAssessmentTypes = map[string]bool{
	domain.TypeMidTerm:    true,
	domain.TypeEndTerm:    true,
	domain.TypeMock:       true,
	domain.TypeDiagnostic: true,
	domain.TypeRemedial:   true,
}

// canCreateAssessmentType reports whether the role may create an assessment of
// the given type — mirrors the client's capability check in lib/core/models/role.dart.
func canCreateAssessmentType(role string, typ string) bool {
	if adminOnlyAssessmentTypes[typ] {
		return role == domain.RoleSuperAdmin ||
			role == domain.RoleSchoolAdmin ||
			role == domain.RoleHeadteacher
	}
	return role == domain.RoleSuperAdmin ||
		role == domain.RoleSchoolAdmin ||
		role == domain.RoleHeadteacher ||
		role == domain.RoleTeacher
}

// listAssessments returns assessments, scoped for students/parents to their
// own class and for teachers to their class (doc §16).
func (s *Server) listAssessments(c *gin.Context) {
	u := currentUser(c)
	all := s.store.Assessments()
	if u.IsSchoolStaff() {
		if subj := c.Query("subject"); subj != "" {
			var filtered []domain.Assessment
			for _, a := range all {
				if a.SubjectID == subj {
					filtered = append(filtered, a)
				}
			}
			sendJSON(c, filtered)
			return
		}
		sendJSON(c, all)
		return
	}
	subj := c.Query("subject")
	var mine []domain.Assessment
	for _, a := range all {
		if subj != "" && a.SubjectID != subj {
			continue
		}
		if s.viewsClass(u, a.ClassID) {
			// Learner roles get the paper without its answer key.
			mine = append(mine, assessmentFor(a, u))
		}
	}
	sendJSON(c, mine)
}

// viewsClass reports whether a non-staff viewer follows classID: a pupil
// their own class, a parent the class of any of their children.
func (s *Server) viewsClass(u domain.User, classID string) bool {
	if classID == "" {
		return false
	}
	switch u.Role {
	case domain.RoleStudent:
		if st, ok := s.store.StudentByID(stringToStudentID(u.ID)); ok {
			return st.ClassID == classID
		}
	case domain.RoleParent:
		for _, id := range u.StudentIDs {
			if st, ok := s.store.StudentByID(id); ok && st.ClassID == classID {
				return true
			}
		}
	}
	return false
}

// createAssessment adds a complete assessment (doc §16).
func (s *Server) createAssessment(c *gin.Context) {
	u := currentUser(c)
	var body domain.Assessment
	if !bind(c, &body) {
		return
	}
	if !validAssessmentTypes[body.Type] {
		fail(c, http.StatusBadRequest, "Unknown assessment type")
		return
	}
	if !canCreateAssessmentType(u.Role, body.Type) {
		fail(c, http.StatusForbidden,
			"Only school admins and headteachers can create "+body.Type+" assessments")
		return
	}
	if body.Title == "" {
		fail(c, http.StatusBadRequest, "title is required")
		return
	}
	if !validSubject(body.SubjectID) {
		fail(c, http.StatusBadRequest, "Unknown subjectId")
		return
	}
	if body.ClassID == "" {
		fail(c, http.StatusBadRequest, "classId is required")
		return
	}
	if _, ok := s.store.ClassByID(body.ClassID); !ok {
		fail(c, http.StatusBadRequest, "classId does not exist")
		return
	}
	if len(body.Questions) == 0 {
		fail(c, http.StatusBadRequest, "at least one question is required")
		return
	}
	// An offline client names its own assessment so screens can refer to it
	// before it syncs; never let that id overwrite an existing one.
	if body.ID != "" {
		if _, exists := s.store.AssessmentByID(body.ID); exists {
			fail(c, http.StatusConflict, "An assessment with this id already exists")
			return
		}
	}
	a := domain.Assessment{
		ID:        firstNonEmpty(body.ID, newID("ASSMT")),
		Title:     body.Title,
		Type:      body.Type,
		SubjectID: body.SubjectID,
		ClassID:   body.ClassID,
		Date:      firstNonEmpty(body.Date, today()),
		CreatedBy: firstNonEmpty(body.CreatedBy, u.Name),
		Questions: body.Questions,
	}
	if writeFailed(c, s.store.SaveAssessment(a)) {
		return
	}
	s.audit(c, "assessment.create", a.ID, "Created "+a.Type+" assessment "+a.Title, "")
	sendCreated(c, a)
}

// learnerQuestion strips the marking key from a question. Learners need the
// stem and options to sit a paper, but correctAnswer/explanation/markingScheme
// ARE the answer key and must not leave the API on a student- or parent-role
// token (the assessment used to be serialised verbatim).
func learnerQuestion(q domain.Question) domain.Question {
	q.CorrectAnswer = ""
	q.Explanation = ""
	q.MarkingScheme = ""
	return q
}

// assessmentFor returns a as it may be serialised for u: staff see the answer
// key, everyone else sees the paper without it.
func assessmentFor(a domain.Assessment, u domain.User) domain.Assessment {
	if u.IsSchoolStaff() {
		return a
	}
	out := a
	if len(a.Questions) > 0 {
		out.Questions = make([]domain.Question, len(a.Questions))
		for i, q := range a.Questions {
			out.Questions[i] = learnerQuestion(q)
		}
	}
	return out
}

// assessmentDetail returns the assessment and the current user's submission if
// one exists.
func (s *Server) assessmentDetail(c *gin.Context) {
	a, ok := s.store.AssessmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	u := currentUser(c)
	if !u.IsSchoolStaff() && !s.viewsClass(u, a.ClassID) {
		fail(c, http.StatusForbidden, "You may only view your own class assessments")
		return
	}
	view := gin.H{"assessment": assessmentFor(a, u)}
	if u.Role == domain.RoleStudent || u.Role == domain.RoleParent {
		sid := ""
		switch u.Role {
		case domain.RoleStudent:
			sid = stringToStudentID(u.ID)
		case domain.RoleParent:
			for _, id := range u.StudentIDs {
				if st, ok := s.store.StudentByID(id); ok && st.ClassID == a.ClassID {
					sid = st.ID
					break
				}
			}
		}
		if sid != "" {
			if sub, found := s.store.SubmissionFor(a.ID, sid); found {
				view["submission"] = sub
			}
		}
	}
	sendJSON(c, view)
}

type blueprintRequest struct {
	Topic      string `json:"topic"`
	SubjectID  string `json:"subjectId"`
	Count      int    `json:"count"`
	ClassID    string `json:"classId"`
	Difficulty string `json:"difficulty"`
}

// blueprintGenerate picks questions from the bank using the same rules as the
// app's blueprintPick and returns a draft assessment with rounded marks
// (doc §18).
func (s *Server) blueprintGenerate(c *gin.Context) {
	id := c.Param("id")
	a, ok := s.store.AssessmentByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	var req blueprintRequest
	if !bind(c, &req) {
		return
	}
	from := s.store.Questions()
	req.Topic = firstNonEmpty(req.Topic, a.SubjectID)
	if req.SubjectID == "" {
		req.SubjectID = a.SubjectID
	}
	if req.Count <= 0 {
		req.Count = 10
	}
	picked := marking.BlueprintPick(from, req.Topic, req.SubjectID, req.Count)
	a.Questions = picked
	draft := a
	draft.ID = newID("ASSMT")
	draft.Title = a.Title + " — Blueprint Draft"
	s.audit(c, "assessment.blueprint", a.ID, "Generated blueprint picking "+itoa(len(picked))+" questions", "")
	sendJSON(c, draft)
}

type submitRequest struct {
	StudentID    string            `json:"studentId"`
	Answers      map[string]string `json:"answers"`
	ClassID      string            `json:"classId"`
	Date         string            `json:"date"`
	DraftPaperID string            `json:"draftPaperId,omitempty"`
}

// submitAssessment marks objective answers instantly (computeEarned) and
// stores the submission pending manual verdicts for subjective questions
// (doc §26, §54).
func (s *Server) submitAssessment(c *gin.Context) {
	id := c.Param("id")
	a, ok := s.store.AssessmentByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	var body submitRequest
	if !bind(c, &body) {
		return
	}
	u := currentUser(c)
	studentID := body.StudentID
	switch {
	case u.Role == domain.RoleStudent:
		// A pupil submits strictly for themselves — a body-supplied studentId
		// for a classmate must never be honoured.
		if studentID != "" && studentID != stringToStudentID(u.ID) {
			fail(c, http.StatusForbidden, "You may only submit your own assessment")
			return
		}
		studentID = stringToStudentID(u.ID)
	case u.IsSchoolStaff():
		if studentID == "" {
			fail(c, http.StatusBadRequest, "studentId is required")
			return
		}
	default:
		// parents and other non-staff audiences have no submit path
		fail(c, http.StatusForbidden, "You may not submit assessments")
		return
	}
	st, ok := s.store.StudentByID(studentID)
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !u.IsSchoolStaff() && a.ClassID != st.ClassID {
		fail(c, http.StatusForbidden, "You may only submit your own class assessments")
		return
	}
	if !teacherCoversClass(u, st.ClassID) {
		fail(c, http.StatusForbidden, "You may only capture work for your own class")
		return
	}
	// A resubmission replaces the whole row, teacher marks included. Staff
	// re-capturing a paper do that on purpose (the app sends the marks again
	// straight after); a pupil re-sending — or their outbox replaying an old
	// submit — must not wipe a result that has already been marked.
	if u.Role == domain.RoleStudent {
		if _, exists := s.store.SubmissionFor(a.ID, st.ID); exists {
			fail(c, http.StatusConflict, "You have already submitted this assessment")
			return
		}
	}
	earned := marking.ComputeEarned(a.Questions, body.Answers, nil)
	sub := domain.Submission{
		ID:           newID("SUB"),
		AssessmentID: a.ID,
		StudentID:    st.ID,
		// Always the pupil's own class: class analytics group on this, so a
		// body naming another class would file the result in the wrong one.
		ClassID:      st.ClassID,
		Date:         firstNonEmpty(body.Date, today()),
		Answers:      body.Answers,
		TeacherMarks: map[string]float64{},
		Earned:       earned,
	}
	if writeFailed(c, s.store.SaveSubmission(sub)) {
		return
	}

	hasSubjective := hasSubjectiveQuestions(a.Questions)
	if hasSubjective {
		s.notifySubjective(c, a, st, sub)
	} else {
		s.notifyAssessmentComplete(a, st, sub)
	}
	s.audit(c, "submission.submit", sub.ID, "Submitted "+a.Title+" by "+st.FullName(), "")

	resp := gin.H{"submission": sub, "autoMarked": earned}
	if hasSubjective {
		resp["pendingVerdicts"] = subjectiveNeedingVerdict(a.Questions, sub)
	}
	sendCreated(c, resp)
}

// markVerdicts records teacher marks per question and recomputes earned
// (doc §26 "mark paper", §54 verdicts).
func (s *Server) markVerdicts(c *gin.Context) {
	id := c.Param("id")
	a, ok := s.store.AssessmentByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	var body struct {
		StudentID    string             `json:"studentId"`
		TeacherMarks map[string]float64 `json:"teacherMarks"`
	}
	if !bind(c, &body) {
		return
	}
	if body.TeacherMarks == nil {
		body.TeacherMarks = map[string]float64{}
	}
	sub, ok := s.store.SubmissionFor(a.ID, body.StudentID)
	if !ok {
		fail(c, http.StatusNotFound, "No submission for this assessment/student")
		return
	}
	if !teacherCoversClass(currentUser(c), sub.ClassID) {
		fail(c, http.StatusForbidden, "You may only mark work for your own class")
		return
	}
	sub.TeacherMarks = clampMarks(a.Questions, body.TeacherMarks)
	remaining := subjectiveNeedingVerdict(a.Questions, sub)
	if len(remaining) > 0 {
		sub.Earned = marking.ComputeEarned(a.Questions, sub.Answers, sub.TeacherMarks)
		if writeFailed(c, s.store.SaveSubmission(sub)) {
			return
		}
		fail(c, http.StatusUnprocessableEntity, "Still "+itoa(len(remaining))+" questions lacking verdicts")
		return
	}
	sub.Earned = marking.ComputeEarned(a.Questions, sub.Answers, sub.TeacherMarks)
	if writeFailed(c, s.store.SaveSubmission(sub)) {
		return
	}

	st, _ := s.store.StudentByID(sub.StudentID)
	var pct float64
	if tm := a.TotalMarks(); tm > 0 {
		pct = 100 * sub.Earned / tm
	}
	if st.ParentUserID != "" {
		s.notify(st.ParentUserID, domain.NotifMarking, a.Title+" marked",
			st.FullName()+" scored "+formatMarks(sub.Earned)+"/"+formatMarks(a.TotalMarks())+" ("+marking.GradeLetter(pct)+").",
			st.ID)
	}
	s.audit(c, "marking.verdicts", sub.ID, "Marked "+a.Title+" for "+st.FullName(), "")
	sendJSON(c, sub)
}

// assessmentResults groups per-student results with distribution (doc §26).
func (s *Server) assessmentResults(c *gin.Context) {
	a, ok := s.store.AssessmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	type row struct {
		Student domain.Student `json:"student"`
		Earned  float64        `json:"earned"`
		Total   float64        `json:"total"`
		Percent float64        `json:"percent"`
		Grade   string         `json:"grade"`
	}
	total := a.TotalMarks()
	var rows []row
	dist := map[string]int{}
	for _, st := range s.store.Students() {
		sub, found := s.store.SubmissionFor(a.ID, st.ID)
		if !found {
			continue
		}
		pct := 0.0
		if total > 0 {
			pct = 100 * sub.Earned / total
		}
		g := marking.GradeLetter(pct)
		dist[g]++
		rows = append(rows, row{Student: st, Earned: sub.Earned, Total: total, Percent: pct, Grade: g})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Percent > rows[j].Percent })
	avg := 0.0
	if len(rows) > 0 {
		for _, r := range rows {
			avg += r.Percent
		}
		avg /= float64(len(rows))
	}
	sendJSON(c, gin.H{
		"assessment":   a,
		"rows":         rows,
		"distribution": dist,
		"average":      avg,
		"submitted":    len(rows),
		"totalMarks":   total,
	})
}

// --- helpers ---

// teacherCoversClass applies the classroom rule to capturing and marking: a
// teacher works on their own class only, school leaders on any. Other roles
// are decided by the caller and the route's own gates.
func teacherCoversClass(u domain.User, classID string) bool {
	return u.Role != domain.RoleTeacher || (classID != "" && classID == u.ClassID)
}

// formatMarks prints a mark without dropping a half: 7.5 stays 7.5 rather
// than truncating to 7, and whole marks print without a trailing ".0".
func formatMarks(v float64) string {
	return strconv.FormatFloat(math.Round(v*100)/100, 'f', -1, 64)
}

func hasSubjectiveQuestions(qs []domain.Question) bool {
	for _, q := range qs {
		if !q.IsObjective() {
			return true
		}
	}
	return false
}

// subjectiveNeedingVerdict returns question ids still lacking a verdict.
func subjectiveNeedingVerdict(qs []domain.Question, sub domain.Submission) []string {
	var out []string
	for _, q := range qs {
		if !q.IsObjective() {
			if _, ok := sub.TeacherMarks[q.ID]; !ok {
				out = append(out, q.ID)
			}
		}
	}
	return out
}

// clampMarks caps teacher marks at each question's max marks.
func clampMarks(qs []domain.Question, marks map[string]float64) map[string]float64 {
	out := map[string]float64{}
	max := map[string]float64{}
	for _, q := range qs {
		max[q.ID] = q.Marks
	}
	for id, v := range marks {
		m, ok := max[id]
		if !ok {
			continue
		}
		if v > m {
			v = m
		}
		if v < 0 {
			v = 0
		}
		out[id] = v
	}
	return out
}

// notifyAssessmentComplete pushes the result notification to the student's
// parent (doc §36).
func (s *Server) notifyAssessmentComplete(a domain.Assessment, st domain.Student, sub domain.Submission) {
	pct := 0.0
	if tm := a.TotalMarks(); tm > 0 {
		pct = 100 * sub.Earned / tm
	}
	if st.ParentUserID != "" {
		s.notify(st.ParentUserID, domain.NotifAssessment, a.Title+" — result available",
			st.FullName()+" scored "+formatMarks(sub.Earned)+"/"+formatMarks(a.TotalMarks())+" ("+marking.GradeLetter(pct)+").",
			st.ID)
	}
}

func (s *Server) notifySubjective(c *gin.Context, a domain.Assessment, st domain.Student, sub domain.Submission) {
	_ = c
	_ = sub
	if st.ParentUserID != "" {
		s.notify(st.ParentUserID, domain.NotifMarking, a.Title+" awaiting marking",
			st.FullName()+" has submitted "+a.Title+". Subjective answers will be reviewed shortly.", st.ID)
	}
}
