package httpapi

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// Endpoints the client's server sync needs on top of the feature routes:
// full (scoped) collection reads it can mirror into its offline store, and
// the update/delete writes its screens already perform locally.

// visibleStudents is the set of student ids u may see, mirroring
// listStudents' scoping. nil means every student.
func (s *Server) visibleStudents(u domain.User) map[string]bool {
	switch u.Role {
	case domain.RoleTeacher:
		ids := map[string]bool{}
		for _, st := range s.store.Students() {
			if st.ClassID == u.ClassID {
				ids[st.ID] = true
			}
		}
		return ids
	case domain.RoleParent:
		ids := map[string]bool{}
		for _, id := range u.StudentIDs {
			ids[id] = true
		}
		return ids
	case domain.RoleStudent:
		return map[string]bool{stringToStudentID(u.ID): true}
	}
	return nil
}

// listNotifications returns every notification visible to the user, read or
// not (unreadNotifications only serves the unread ones).
func (s *Server) listNotifications(c *gin.Context) {
	u := currentUser(c)
	out := []domain.Notification{}
	for _, n := range s.store.Notifications() {
		if notificationAllowed(u, n) {
			out = append(out, n)
		}
	}
	sendJSON(c, out)
}

// listAttendance returns the attendance records of every student the user
// may see.
func (s *Server) listAttendance(c *gin.Context) {
	visible := s.visibleStudents(currentUser(c))
	out := []domain.AttendanceRecord{}
	for _, r := range s.store.Attendance() {
		if visible == nil || visible[r.StudentID] {
			out = append(out, r)
		}
	}
	sendJSON(c, out)
}

// listSubmissions returns the assessment submissions of every student the
// user may see.
func (s *Server) listSubmissions(c *gin.Context) {
	visible := s.visibleStudents(currentUser(c))
	out := []domain.Submission{}
	for _, sub := range s.store.Submissions() {
		if visible == nil || visible[sub.StudentID] {
			out = append(out, sub)
		}
	}
	sendJSON(c, out)
}

type updateUserRequest struct {
	Name       *string   `json:"name"`
	Phone      *string   `json:"phone"`
	Role       *string   `json:"role"`
	ClassID    *string   `json:"classId"`
	StudentIDs *[]string `json:"studentIds"`
}

// updateUser edits an account's profile, role, class and linked children.
// Fields left out of the body are unchanged; the password has its own route.
func (s *Server) updateUser(c *gin.Context) {
	u := currentUser(c)
	target, ok := s.store.UserByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "User not found")
		return
	}
	if !u.IsSuperAdmin() && (target.Role == domain.RoleSuperAdmin || target.SchoolID != u.SchoolID) {
		fail(c, http.StatusForbidden, "You may only edit accounts in your school")
		return
	}
	var body updateUserRequest
	if !bind(c, &body) {
		return
	}
	if body.Name != nil {
		name := strings.TrimSpace(*body.Name)
		if name == "" {
			fail(c, http.StatusBadRequest, "name is required")
			return
		}
		target.Name = name
	}
	if body.Phone != nil {
		target.Phone = *body.Phone
	}
	if body.Role != nil {
		if !validRole(*body.Role) {
			fail(c, http.StatusBadRequest, "unknown role")
			return
		}
		if *body.Role == domain.RoleSuperAdmin && !u.IsSuperAdmin() {
			fail(c, http.StatusForbidden, "only the super admin can grant super admin")
			return
		}
		target.Role = *body.Role
	}
	if body.ClassID != nil {
		target.ClassID = *body.ClassID
	}
	if body.StudentIDs != nil {
		for _, id := range *body.StudentIDs {
			if _, ok := s.store.StudentByID(id); !ok {
				fail(c, http.StatusBadRequest, "Unknown student "+id)
				return
			}
		}
		target.StudentIDs = *body.StudentIDs
	}
	if writeFailed(c, s.store.SaveUser(target)) {
		return
	}
	s.audit(c, "user.update", target.ID, "Updated "+target.Role+" account "+target.Name, "")
	target.Password = ""
	sendJSON(c, target)
}

// saveClass creates or updates a class (the id is the class code, e.g. JHS2A).
func (s *Server) saveClass(c *gin.Context) {
	var body domain.ClassRoom
	if !bind(c, &body) {
		return
	}
	body.ID = c.Param("id")
	if strings.TrimSpace(body.Name) == "" {
		fail(c, http.StatusBadRequest, "name is required")
		return
	}
	if body.TeacherID != "" {
		if t, ok := s.store.UserByID(body.TeacherID); !ok || t.Role != domain.RoleTeacher {
			fail(c, http.StatusBadRequest, "teacherId must be a teacher account")
			return
		}
	}
	if writeFailed(c, s.store.SaveClass(body)) {
		return
	}
	s.audit(c, "class.save", body.ID, "Saved class "+body.Name+" "+body.Stream, "")
	sendJSON(c, body)
}

// deleteClass removes a class nothing refers to any more: no students,
// assessments, assignments or attendance.
func (s *Server) deleteClass(c *gin.Context) {
	id := c.Param("id")
	cls, ok := s.store.ClassByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Class not found")
		return
	}
	inUse := ""
	for _, st := range s.store.Students() {
		if st.ClassID == id {
			inUse = "students"
			break
		}
	}
	if inUse == "" {
		for _, a := range s.store.Assessments() {
			if a.ClassID == id {
				inUse = "assessments"
				break
			}
		}
	}
	if inUse == "" {
		for _, a := range s.store.Assignments() {
			if a.ClassID == id {
				inUse = "assignments"
				break
			}
		}
	}
	if inUse == "" {
		for _, r := range s.store.Attendance() {
			if r.ClassID == id {
				inUse = "attendance records"
				break
			}
		}
	}
	if inUse != "" {
		fail(c, http.StatusConflict, "This class still has "+inUse+" and cannot be removed")
		return
	}
	if writeFailed(c, s.store.DeleteClass(id)) {
		return
	}
	s.audit(c, "class.delete", id, "Removed class "+cls.Name+" "+cls.Stream, "")
	sendJSON(c, gin.H{"deleted": id})
}

// updateAssessment replaces an existing assessment's paper and details,
// with the same checks as createAssessment.
func (s *Server) updateAssessment(c *gin.Context) {
	u := currentUser(c)
	existing, ok := s.store.AssessmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	var body domain.Assessment
	if !bind(c, &body) {
		return
	}
	if !validAssessmentTypes[body.Type] {
		fail(c, http.StatusBadRequest, "Unknown assessment type")
		return
	}
	if !canCreateAssessmentType(u.Role, body.Type) || !canCreateAssessmentType(u.Role, existing.Type) {
		fail(c, http.StatusForbidden,
			"Only school admins and headteachers can edit "+existing.Type+" assessments")
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
	if _, ok := s.store.ClassByID(body.ClassID); !ok {
		fail(c, http.StatusBadRequest, "classId does not exist")
		return
	}
	if len(body.Questions) == 0 {
		fail(c, http.StatusBadRequest, "at least one question is required")
		return
	}
	a := domain.Assessment{
		ID:        existing.ID,
		Title:     body.Title,
		Type:      body.Type,
		SubjectID: body.SubjectID,
		ClassID:   body.ClassID,
		Date:      firstNonEmpty(body.Date, existing.Date),
		CreatedBy: existing.CreatedBy,
		Questions: body.Questions,
	}
	if writeFailed(c, s.store.SaveAssessment(a)) {
		return
	}
	s.audit(c, "assessment.update", a.ID, "Updated "+a.Type+" assessment "+a.Title, "")
	sendJSON(c, a)
}

// deleteAnnouncement removes an announcement. School admins and headteachers
// may remove any; other staff only their own.
func (s *Server) deleteAnnouncement(c *gin.Context) {
	u := currentUser(c)
	id := c.Param("id")
	var found *domain.Announcement
	for _, a := range s.store.Announcements() {
		if a.ID == id {
			a := a
			found = &a
			break
		}
	}
	if found == nil {
		fail(c, http.StatusNotFound, "Announcement not found")
		return
	}
	admin := u.IsSuperAdmin() || u.Role == domain.RoleSchoolAdmin || u.Role == domain.RoleHeadteacher
	if !admin && found.AuthorID != u.ID {
		fail(c, http.StatusForbidden, "You may only remove your own announcements")
		return
	}
	if writeFailed(c, s.store.DeleteAnnouncement(id)) {
		return
	}
	s.audit(c, "announcement.delete", id, "Removed announcement "+found.Title, "")
	sendJSON(c, gin.H{"deleted": id})
}

// deleteAssignment removes an assignment and its completions.
func (s *Server) deleteAssignment(c *gin.Context) {
	a, ok := s.store.AssignmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assignment not found")
		return
	}
	if writeFailed(c, s.store.DeleteAssignment(a.ID)) {
		return
	}
	s.audit(c, "assignment.delete", a.ID, "Removed assignment "+a.Title, "")
	sendJSON(c, gin.H{"deleted": a.ID})
}
