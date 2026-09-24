package httpapi

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/marking"
)

// studentResults returns each assessment's result for a student, mirroring
// reporting_service.subjectPerformance (doc §28).
func (s *Server) studentResults(c *gin.Context) {
	st, ok := s.store.StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	type result struct {
		Assessment domain.Assessment `json:"assessment"`
		Subject    string            `json:"subject"`
		Marks      float64           `json:"marks"`
		Total      float64           `json:"total"`
		Percent    float64           `json:"percent"`
		Grade      string            `json:"grade"`
	}
	var out []result
	for _, a := range s.store.Assessments() {
		if a.ClassID != st.ClassID {
			continue
		}
		sub, found := s.store.SubmissionFor(a.ID, st.ID)
		if !found || sub.ClassID != st.ClassID {
			continue
		}
		total := a.TotalMarks()
		pct := 0.0
		if total > 0 {
			pct = 100 * sub.Earned / total
		}
		out = append(out, result{
			Assessment: a, Subject: domain.SubjectName(a.SubjectID),
			Marks: sub.Earned, Total: total, Percent: pct, Grade: marking.GradeLetter(pct),
		})
	}
	sendJSON(c, out)
}

// studentWeakTopics returns topic-level accuracy (<100% listed) for prep and
// vacation features (doc §44–45).
func (s *Server) studentWeakTopics(c *gin.Context) {
	st, ok := s.store.StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	subs := s.store.Submissions()
	topics := marking.WeakTopics(st.ID, s.store.Assessments(), subs)
	out := make([]map[string]any, 0, len(topics))
	for _, t := range topics {
		out = append(out, map[string]any{
			"subjectId": t.SubjectID,
			"topic":     t.Topic,
			"pct":       t.Pct,
			"correct":   t.Correct,
			"total":     t.Total,
		})
	}
	sendJSON(c, out)
}

// classGaps returns the per-question learning gaps for an assessment, sorted
// worst-first (doc §29–30).
func (s *Server) classGaps(c *gin.Context) {
	assessmentID := c.Query("assessmentId")
	if assessmentID == "" {
		fail(c, http.StatusBadRequest, "assessmentId query required")
		return
	}
	a, ok := s.store.AssessmentByID(assessmentID)
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	cp := marking.ClassPerformance{Assessments: s.store.Assessments(), Subs: s.store.Submissions(), Students: s.store.Students()}
	gaps := cp.Gaps(a)
	sendJSON(c, gin.H{"assessmentId": a.ID, "subjectId": a.SubjectID, "gaps": gaps})
}

// atRisk lists students averaging below the threshold with suggested
// interventions (doc §27).
func (s *Server) atRisk(c *gin.Context) {
	threshold := 60.0
	if v := c.Query("threshold"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			threshold = f
		}
	}
	cp := marking.ClassPerformance{Assessments: s.store.Assessments(), Subs: s.store.Submissions(), Students: s.store.Students()}
	sendJSON(c, cp.AtRisk(threshold))
}
