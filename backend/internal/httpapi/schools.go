package httpapi

import (
	"errors"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// schoolListing is a school in the platform directory.
type schoolListing struct {
	domain.School
	Suspended bool `json:"suspended"`
}

// listSchools is the platform's school directory (super admin only).
func (s *Server) listSchools(c *gin.Context) {
	out := []schoolListing{}
	for _, id := range s.tenants.Schools() {
		st, err := s.tenants.For(id)
		if err != nil {
			continue
		}
		sc := st.School()
		if sc.ID == "" {
			sc.ID = id
		}
		out = append(out, schoolListing{School: sc, Suspended: s.tenants.Suspended(id)})
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

const suspendedMessage = "This school's access is suspended. Please contact SOLVANTA."

// schoolStore is the store of the school named in the path.
func (s *Server) schoolInPath(c *gin.Context) (string, store.Store, bool) {
	id := c.Param("id")
	st, err := s.tenants.For(id)
	if err != nil {
		fail(c, http.StatusNotFound, "School not found")
		return "", nil, false
	}
	return id, st, true
}

// updateSchoolProfile edits any school's profile (super admin).
func (s *Server) updateSchoolProfile(c *gin.Context) {
	id, st, ok := s.schoolInPath(c)
	if !ok {
		return
	}
	var body domain.School
	if !bind(c, &body) {
		return
	}
	old := st.School()
	body.ID = id
	body.Name = firstNonEmpty(strings.TrimSpace(body.Name), old.Name)
	if writeFailed(c, st.SaveSchool(body)) {
		return
	}
	s.audit(c, "school.edit", id, "Edited school "+body.Name, "")
	sendJSON(c, body)
}

// suspendSchool switches a school's access off (everyone in it is refused
// at once) or back on. Its data is untouched.
func (s *Server) suspendSchool(suspend bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, _, ok := s.schoolInPath(c)
		if !ok {
			return
		}
		if suspend && id == domain.DefaultSchoolID() {
			fail(c, http.StatusConflict, "The platform's own school can't be suspended")
			return
		}
		if writeFailed(c, s.tenants.SetSuspended(id, suspend)) {
			return
		}
		action := "school.activate"
		if suspend {
			action = "school.suspend"
		}
		s.audit(c, action, id, action+" "+id, "")
		sendJSON(c, gin.H{"id": id, "suspended": suspend})
	}
}

// exportSchool is a full JSON copy of one school's data, for the school or
// for safekeeping. (Database backups are per schema: see docs/DEPLOYMENT.md.)
func (s *Server) exportSchool(c *gin.Context) {
	id, st, ok := s.schoolInPath(c)
	if !ok {
		return
	}
	records := gin.H{}
	for kind := range recordKinds {
		records[kind] = st.Records(kind)
	}
	grading, _ := st.GradingConfig(id)
	s.audit(c, "school.export", id, "Exported school "+id, "")
	c.Header("Content-Disposition", `attachment; filename="`+id+`-export.json"`)
	sendJSON(c, gin.H{
		"exportedAt": now(), "schoolId": id,
		"school": st.School(), "term": st.Term(), "finishedTerms": st.FinishedTerms(id),
		"grading": grading, "users": st.Users(), "classes": st.Classes(),
		"students": st.Students(), "attendance": st.Attendance(), "gate": st.GateEvents(),
		"questions": st.Questions(), "aiRequests": st.AIRequests(),
		"assessments": st.Assessments(), "submissions": st.Submissions(),
		"markingSchemes": st.MarkingSchemes(), "interventions": st.Interventions(),
		"messages": st.Messages(), "announcements": st.Announcements(),
		"notifications": st.Notifications(), "assignments": st.Assignments(),
		"invoices": st.Invoices(), "payments": st.Payments(),
		"audit": st.AuditLogs(), "records": records,
	})
}

// deleteSchool removes a school and all its data for good. It must be
// suspended first, and the request must repeat its id (?confirm=ID).
func (s *Server) deleteSchool(c *gin.Context) {
	id, _, ok := s.schoolInPath(c)
	if !ok {
		return
	}
	switch {
	case c.Query("confirm") != id:
		fail(c, http.StatusBadRequest, "Repeat the school id in ?confirm= to delete it")
		return
	case !s.tenants.Suspended(id):
		fail(c, http.StatusConflict, "Suspend the school before deleting it")
		return
	}
	if err := s.tenants.Delete(id); errors.Is(err, store.ErrDefaultSchool) {
		fail(c, http.StatusConflict, "The platform's own school can't be deleted")
		return
	} else if writeFailed(c, err) {
		return
	}
	s.audit(c, "school.delete", id, "Deleted school "+id+" and all its data", "")
	sendJSON(c, gin.H{"deleted": id})
}
