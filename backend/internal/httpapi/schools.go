package httpapi

import (
	"errors"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// listSchools is the platform's school directory (super admin only).
func (s *Server) listSchools(c *gin.Context) {
	out := []domain.School{}
	for _, id := range s.tenants.Schools() {
		st, err := s.tenants.For(id)
		if err != nil {
			continue
		}
		sc := st.School()
		if sc.ID == "" {
			sc.ID = id
		}
		out = append(out, sc)
	}
	sendJSON(c, out)
}

// createSchool registers a new school with an empty store of its own (super
// admin only). Its admin is then created with POST /api/users and this
// school's id, and does the rest — term, classes, grading — themselves.
func (s *Server) createSchool(c *gin.Context) {
	var body domain.School
	if !bind(c, &body) {
		return
	}
	body.ID = strings.ToUpper(strings.TrimSpace(body.ID))
	body.Name = strings.TrimSpace(body.Name)
	if !store.ValidSchoolID(body.ID) || body.Name == "" {
		fail(c, http.StatusBadRequest, "a school needs an id (letters, digits, - or _) and a name")
		return
	}
	st, err := s.tenants.Create(body.ID)
	switch {
	case errors.Is(err, store.ErrSchoolExists):
		fail(c, http.StatusConflict, "A school with this id already exists")
		return
	case err != nil:
		fail(c, http.StatusInternalServerError, "Could not create the school")
		return
	}
	if writeFailed(c, st.SaveSchool(body)) {
		return
	}
	s.audit(c, "school.create", body.ID, "Created school "+body.Name, "")
	sendCreated(c, body)
}
