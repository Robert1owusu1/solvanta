package httpapi

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

var validInterventionStatus = map[string]bool{
	domain.IntOpen: true, domain.IntInProgress: true,
	domain.IntCompleted: true, domain.IntCancelled: true,
}

// listInterventions returns all interventions (staff) or those for the
// caller's own students (parents).
func (s *Server) listInterventions(c *gin.Context) {
	u := currentUser(c)
	if u.IsSchoolStaff() {
		sendJSON(c, s.store.Interventions())
		return
	}
	var out []domain.Intervention
	for _, id := range u.StudentIDs {
		out = append(out, s.store.InterventionsForStudent(id)...)
	}
	sendJSON(c, out)
}

// interventionsForStudent returns a student's interventions newest-first.
func (s *Server) interventionsForStudent(c *gin.Context) {
	st, ok := s.store.StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	sendJSON(c, s.store.InterventionsForStudent(st.ID))
}

// createIntervention assigns one (doc §31).
func (s *Server) createIntervention(c *gin.Context) {
	u := currentUser(c)
	var body domain.Intervention
	if !bind(c, &body) {
		return
	}
	if _, ok := s.store.StudentByID(body.StudentID); !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	i := domain.Intervention{
		ID:          newID("INTV"),
		StudentID:   body.StudentID,
		Topic:       body.Topic,
		Action:      body.Action,
		AssignedBy:  firstNonEmpty(body.AssignedBy, u.Name),
		CreatedDate: firstNonEmpty(body.CreatedDate, today()),
		Status:      domain.IntOpen,
	}
	s.store.SaveIntervention(i)
	st, _ := s.store.StudentByID(i.StudentID)
	if st.ParentUserID != "" {
		s.notify(st.ParentUserID, domain.NotifIntervention, "Intervention assigned",
			st.FullName()+" has a new learning intervention on "+i.Topic+".", st.ID)
	}
	s.audit(c, "intervention.create", i.ID, "Assigned intervention on "+i.Topic+" to "+st.FullName(), "")
	sendCreated(c, i)
}

type statusUpdate struct {
	Status string `json:"status"`
}

// updateInterventionStatus moves an intervention open → inProgress → completed.
func (s *Server) updateInterventionStatus(c *gin.Context) {
	var body statusUpdate
	if !bind(c, &body) {
		return
	}
	if !validInterventionStatus[body.Status] {
		fail(c, http.StatusBadRequest, "Invalid status")
		return
	}
	i, ok := s.store.InterventionByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Intervention not found")
		return
	}
	i.Status = body.Status
	s.store.SaveIntervention(i)
	st, _ := s.store.StudentByID(i.StudentID)
	if st.ParentUserID != "" {
		s.notify(st.ParentUserID, domain.NotifIntervention, "Intervention "+stringStatus(body.Status),
			"The intervention on "+i.Topic+" for "+st.FullName()+" is now "+stringStatus(body.Status)+".", st.ID)
	}
	s.audit(c, "intervention.status", i.ID, "Status → "+body.Status+" for "+st.FullName(), "")
	sendJSON(c, i)
}

// attachReassessment links the reassessment used to verify improvement (doc §32).
func (s *Server) attachReassessment(c *gin.Context) {
	var body struct {
		AssessmentID string `json:"assessmentId"`
	}
	if !bind(c, &body) {
		return
	}
	if _, ok := s.store.AssessmentByID(body.AssessmentID); !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	i, ok := s.store.InterventionByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Intervention not found")
		return
	}
	i.ReassessmentAssessmentID = body.AssessmentID
	s.store.SaveIntervention(i)
	s.audit(c, "intervention.reassessment", i.ID, "Reassessment "+body.AssessmentID+" attached", "")
	sendJSON(c, i)
}

// interventionImprovement compares pre-intervention performance on the topic
// with the linked reassessment result (doc §32).
func (s *Server) interventionImprovement(c *gin.Context) {
	i, ok := s.store.InterventionByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Intervention not found")
		return
	}
	st, ok := s.store.StudentByID(i.StudentID)
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	before := s.averageOnTopic(st.ID, i.Topic, "")
	var after float64
	if i.ReassessmentAssessmentID != "" {
		after = s.averageOnTopic(st.ID, i.Topic, i.ReassessmentAssessmentID)
		if after == 0 {
			after = s.assessmentPercent(st.ID, i.ReassessmentAssessmentID)
		}
	}
	sendJSON(c, gin.H{
		"intervention":      i,
		"before":            before,
		"after":             after,
		"improvement":       after - before,
		"status":            i.Status,
		"reassessmentGiven": i.ReassessmentAssessmentID != "",
	})
}

// averageOnTopic returns the student's average % on objective questions of a
// topic (optionally limited to one assessment).
func (s *Server) averageOnTopic(studentID, topic, assessmentID string) float64 {
	var correct, total float64
	for _, a := range s.store.Assessments() {
		if assessmentID != "" && a.ID != assessmentID {
			continue
		}
		sub, ok := s.store.SubmissionFor(a.ID, studentID)
		if !ok {
			continue
		}
		for _, q := range a.Questions {
			if q.Topic != topic || !q.IsObjective() {
				continue
			}
			total++
			got := strings.ToLower(strings.TrimSpace(sub.Answers[q.ID]))
			if got != "" && got == strings.ToLower(strings.TrimSpace(q.CorrectAnswer)) {
				correct++
			}
		}
	}
	if total == 0 {
		return 0
	}
	return 100 * correct / total
}

// assessmentPercent returns the student's overall percentage for an assessment.
func (s *Server) assessmentPercent(studentID, assessmentID string) float64 {
	a, ok := s.store.AssessmentByID(assessmentID)
	if !ok {
		return 0
	}
	sub, ok := s.store.SubmissionFor(assessmentID, studentID)
	if !ok {
		return 0
	}
	tm := a.TotalMarks()
	if tm <= 0 {
		return 0
	}
	return 100 * sub.Earned / tm
}

func stringStatus(status string) string {
	switch status {
	case domain.IntOpen:
		return "open"
	case domain.IntInProgress:
		return "in progress"
	case domain.IntCompleted:
		return "completed"
	case domain.IntCancelled:
		return "cancelled"
	}
	return status
}
