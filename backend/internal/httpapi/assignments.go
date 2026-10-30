package httpapi

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// listAssignments returns assignments for the caller's class (or all for
// school leadership).
func (s *Server) listAssignments(c *gin.Context) {
	u := currentUser(c)
	var out []domain.Assignment
	for _, a := range s.db(c).Assignments() {
		if u.IsSchoolStaff() || s.viewsClass(c, u, a.ClassID) {
			out = append(out, a)
		}
	}
	sendJSON(c, out)
}

func (s *Server) createAssignment(c *gin.Context) {
	u := currentUser(c)
	var body domain.Assignment
	if !bind(c, &body) {
		return
	}
	a := domain.Assignment{
		ID:           newID("ASG"),
		ClassID:      firstNonEmpty(body.ClassID, u.ClassID),
		SubjectID:    body.SubjectID,
		Title:        body.Title,
		Instructions: body.Instructions,
		Deadline:     body.Deadline,
		CreatedBy:    firstNonEmpty(body.CreatedBy, u.Name),
		CreatedAt:    today(),
	}
	if writeFailed(c, s.db(c).SaveAssignment(a)) {
		return
	}
	// notify parents of target class
	seen := map[string]bool{}
	for _, st := range s.db(c).Students() {
		if st.ClassID != a.ClassID || st.ParentUserID == "" {
			continue
		}
		if seen[st.ParentUserID] {
			continue
		}
		seen[st.ParentUserID] = true
		s.notify(c, st.ParentUserID, domain.NotifAssignment, "New "+domain.SubjectName(a.SubjectID)+" assignment",
			a.Title+" — due "+a.Deadline, st.ID)
	}
	s.audit(c, "assignment.create", a.ID, "Assignment "+a.Title+" for "+a.ClassID, "")
	sendCreated(c, a)
}

func (s *Server) completeAssignment(c *gin.Context) {
	a, ok := s.db(c).AssignmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assignment not found")
		return
	}
	u := currentUser(c)
	studentID := stringToStudentID(u.ID)
	for _, done := range a.CompletedBy {
		if done == studentID {
			sendJSON(c, a)
			return
		}
	}
	a.CompletedBy = append(a.CompletedBy, studentID)
	if writeFailed(c, s.db(c).SaveAssignment(a)) {
		return
	}
	if st, ok := s.db(c).StudentByID(studentID); ok && st.ParentUserID != "" {
		s.notify(c, st.ParentUserID, domain.NotifAssignment, st.FullName()+" submitted an assignment",
			"Completed \""+a.Title+"\" — "+a.Instructions, st.ID)
	}
	sendJSON(c, a)
}

// uncompleteAssignment takes back a pupil's own completion, for a box ticked
// by mistake.
func (s *Server) uncompleteAssignment(c *gin.Context) {
	a, ok := s.db(c).AssignmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assignment not found")
		return
	}
	studentID := stringToStudentID(currentUser(c).ID)
	kept := []string{}
	for _, done := range a.CompletedBy {
		if done != studentID {
			kept = append(kept, done)
		}
	}
	if len(kept) == len(a.CompletedBy) {
		sendJSON(c, a)
		return
	}
	a.CompletedBy = kept
	if writeFailed(c, s.db(c).SaveAssignment(a)) {
		return
	}
	sendJSON(c, a)
}
