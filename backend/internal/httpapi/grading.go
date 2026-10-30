package httpapi

import (
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// gradingSchool is the school a grading request is about: the caller's own,
// or — for a super admin only — the one named by ?schoolId=. schoolScope has
// already refused anyone else naming a school that isn't theirs.
func (s *Server) gradingSchool(c *gin.Context) string {
	u := currentUser(c)
	if id := c.Query("schoolId"); id != "" && u.IsSuperAdmin() {
		return id
	}
	return s.userSchool(u)
}

// gradingConfig returns the school's grading set-up, or the GES default
// until its admin has saved one. Everyone in the school reads it: report
// cards and results are graded with it on every device.
func (s *Server) gradingConfig(c *gin.Context) {
	school := s.gradingSchool(c)
	if g, ok := s.store.GradingConfig(school); ok {
		sendJSON(c, g)
		return
	}
	sendJSON(c, domain.DefaultGradingConfig(school))
}

// saveGradingConfig replaces the school's grading set-up after checking
// every rule the editor checks, since a client can send anything.
func (s *Server) saveGradingConfig(c *gin.Context) {
	var body domain.GradingConfig
	if !bind(c, &body) {
		return
	}
	if err := body.Normalize(); err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}
	u := currentUser(c)
	body.SchoolID = s.gradingSchool(c) // never taken from the body
	body.UpdatedAt = now()
	body.UpdatedBy = u.Name
	if writeFailed(c, s.store.SaveGradingConfig(body)) {
		return
	}
	s.audit(c, "grading.update", body.SchoolID,
		fmt.Sprintf("Grading set-up saved (%d scheme(s))", len(body.Schemes)), "")
	sendJSON(c, body)
}
