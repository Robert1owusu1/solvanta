package httpapi

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// listStudents returns students, scoped by role (doc §10):
// superAdmin/schoolAdmin/headteacher → all; teacher → own class;
// parent → their children; student → themselves.
func (s *Server) listStudents(c *gin.Context) {
	u := currentUser(c)
	all := s.db(c).Students()
	if u.IsSuperAdmin() || u.Role == domain.RoleSchoolAdmin || u.Role == domain.RoleHeadteacher || u.Role == domain.RoleStaff {
		sendJSON(c, all)
		return
	}
	switch u.Role {
	case domain.RoleTeacher:
		var out []domain.Student
		for _, st := range all {
			if st.ClassID == u.ClassID {
				out = append(out, st)
			}
		}
		sendJSON(c, out)
	case domain.RoleParent:
		var out []domain.Student
		for _, id := range u.StudentIDs {
			if st, found := s.db(c).StudentByID(id); found {
				out = append(out, st)
			}
		}
		sendJSON(c, out)
	case domain.RoleStudent:
		if st, found := s.db(c).StudentByID(stringToStudentID(u.ID)); found {
			sendJSON(c, []domain.Student{st})
			return
		}
		sendJSON(c, []domain.Student{})
	default:
		sendJSON(c, all)
	}
}

// stringToStudentID mirrors the app's me.id.replaceFirst('USR-', ”).
func stringToStudentID(userID string) string {
	if len(userID) > 4 && userID[:4] == "USR-" {
		return userID[4:]
	}
	return userID
}

// canViewStudent gates single-student reads: staff see everyone, students see
// themselves, parents see their own children.
func (s *Server) canViewStudent(u domain.User, st domain.Student) bool {
	if u.IsSchoolStaff() {
		return true
	}
	if u.Role == domain.RoleStudent {
		return stringToStudentID(u.ID) == st.ID
	}
	if u.Role == domain.RoleParent {
		for _, id := range u.StudentIDs {
			if id == st.ID {
				return true
			}
		}
	}
	return false
}

type studentRequest struct {
	ID                string          `json:"id"`
	FirstName         string          `json:"firstName"`
	LastName          string          `json:"lastName"`
	Gender            string          `json:"gender"`
	DateOfBirth       string          `json:"dateOfBirth"`
	AdmissionDate     string          `json:"admissionDate"`
	AdmissionNo       string          `json:"admissionNo"`
	ClassID           string          `json:"classId"`
	SchoolID          string          `json:"schoolId"`
	Guardians         []domain.Person `json:"guardians"`
	EmergencyContacts []domain.Person `json:"emergencyContacts"`
	AuthorizedPickup  []domain.Person `json:"authorizedPickup"`
	ParentUserID      *string         `json:"parentUserId,omitempty"`
	Status            string          `json:"status,omitempty"`
}

// createStudent adds a student (doc §10).
func (s *Server) createStudent(c *gin.Context) {
	var body studentRequest
	if !bind(c, &body) {
		return
	}
	u := currentUser(c)
	if firstNonEmpty(body.FirstName, body.LastName) == "" {
		fail(c, http.StatusBadRequest, "firstName and lastName are required")
		return
	}
	if body.Gender != "M" && body.Gender != "F" {
		fail(c, http.StatusBadRequest, "gender must be 'M' or 'F'")
		return
	}
	if body.ClassID == "" {
		fail(c, http.StatusBadRequest, "classId is required")
		return
	}
	if _, ok := s.db(c).ClassByID(body.ClassID); !ok {
		fail(c, http.StatusBadRequest, "classId does not exist")
		return
	}
	st := domain.Student{
		ID:                firstNonEmpty(body.ID, newID("STU")),
		FirstName:         body.FirstName,
		LastName:          body.LastName,
		Gender:            body.Gender,
		DateOfBirth:       body.DateOfBirth,
		AdmissionDate:     firstNonEmpty(body.AdmissionDate, today()),
		AdmissionNo:       body.AdmissionNo,
		ClassID:           body.ClassID,
		SchoolID:          firstNonEmpty(body.SchoolID, s.userSchool(u)),
		ParentUserID:      deref(body.ParentUserID),
		Status:            firstNonEmpty(body.Status, "Active"),
		Guardians:         body.Guardians,
		EmergencyContacts: body.EmergencyContacts,
		AuthorizedPickup:  body.AuthorizedPickup,
	}
	if writeFailed(c, s.db(c).SaveStudent(st)) {
		return
	}
	s.audit(c, "student.create", st.ID, "Created student "+st.FullName(), "")
	sendCreated(c, st)
}

// studentDetail returns a student with related guardian/pickup info (doc §80).
func (s *Server) studentDetail(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	var parent *domain.User
	if st.ParentUserID != "" {
		if p, found := s.db(c).UserByID(st.ParentUserID); found {
			parent = &p
		}
	}
	sendJSON(c, gin.H{
		"student":       st,
		"parent":        parent,
		"contactDetail": structuralDetail(st),
	})
}

func structuralDetail(st domain.Student) map[string]any {
	return map[string]any{
		"authorizedPickup":  st.AuthorizedPickup,
		"emergencyContacts": st.EmergencyContacts,
		"guardians":         st.Guardians,
	}
}

// updateStudent edits profile fields.
func (s *Server) updateStudent(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	var body studentRequest
	if !bind(c, &body) {
		return
	}
	if body.FirstName != "" {
		st.FirstName = body.FirstName
	}
	if body.LastName != "" {
		st.LastName = body.LastName
	}
	if body.Gender != "" {
		st.Gender = body.Gender
	}
	if body.DateOfBirth != "" {
		st.DateOfBirth = body.DateOfBirth
	}
	if body.ClassID != "" {
		st.ClassID = body.ClassID
	}
	if body.AdmissionNo != "" {
		st.AdmissionNo = body.AdmissionNo
	}
	if body.AdmissionDate != "" {
		st.AdmissionDate = body.AdmissionDate
	}
	if body.Status != "" {
		st.Status = body.Status
	}
	// Present-but-empty unlinks the parent; absent leaves the link alone.
	if body.ParentUserID != nil {
		if id := *body.ParentUserID; id != "" {
			if p, ok := s.db(c).UserByID(id); !ok || p.Role != domain.RoleParent {
				fail(c, http.StatusBadRequest, "parentUserId must be a parent account")
				return
			}
		}
		st.ParentUserID = *body.ParentUserID
	}
	if body.Guardians != nil {
		st.Guardians = body.Guardians
	}
	if body.EmergencyContacts != nil {
		st.EmergencyContacts = body.EmergencyContacts
	}
	if body.AuthorizedPickup != nil {
		st.AuthorizedPickup = body.AuthorizedPickup
	}
	if writeFailed(c, s.db(c).SaveStudent(st)) {
		return
	}
	s.audit(c, "student.update", st.ID, "Updated student "+st.FullName(), "")
	sendJSON(c, st)
}

// promoteStudent moves a student to the next class (doc §78).
func (s *Server) promoteStudent(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	next := st.PromotedToClass()
	if next == "" {
		fail(c, http.StatusBadRequest, "No higher class available")
		return
	}
	st.ClassID = next
	if writeFailed(c, s.db(c).SaveStudent(st)) {
		return
	}
	s.audit(c, "student.promote", st.ID, "Promoted "+st.FullName()+" to "+next, "")
	sendJSON(c, st)
}

// graduateStudent marks a student as graduated (doc §78).
func (s *Server) graduateStudent(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	st.Status = "graduated"
	if writeFailed(c, s.db(c).SaveStudent(st)) {
		return
	}
	s.audit(c, "student.graduate", st.ID, "Graduated "+st.FullName(), "")
	sendJSON(c, st)
}

// authorizePickup appends a person to the authorized pickup list (doc §13).
func (s *Server) authorizePickup(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	var p domain.Person
	if !bind(c, &p) {
		return
	}
	st.AuthorizedPickup = append(st.AuthorizedPickup, domain.Person{Name: p.Name, Phone: p.Phone, Relation: p.Relation})
	if writeFailed(c, s.db(c).SaveStudent(st)) {
		return
	}
	s.audit(c, "pickup.authorize", st.ID, p.Name+" authorized for "+st.FullName(), "")
	s.notify(c, userForStudent(c, s, st).ID, domain.NotifGate, "Pickup authorization updated",
		p.Name+" is now on the authorized pickup list for "+st.FullName()+".", st.ID)
	sendJSON(c, st.AuthorizedPickup)
}

// revokePickup removes a person by name/phone from the authorized list.
func (s *Server) revokePickup(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	var p domain.Person
	if !bind(c, &p) {
		return
	}
	var kept []domain.Person
	for _, existing := range st.AuthorizedPickup {
		if existing.Name == p.Name && (p.Phone == "" || existing.Phone == p.Phone) {
			continue
		}
		kept = append(kept, existing)
	}
	st.AuthorizedPickup = kept
	if writeFailed(c, s.db(c).SaveStudent(st)) {
		return
	}
	s.audit(c, "pickup.revoke", st.ID, p.Name+" removed for "+st.FullName(), "")
	sendJSON(c, st.AuthorizedPickup)
}

// userForStudent returns the parent account linked to a student, if any.
func userForStudent(c *gin.Context, s *Server, st domain.Student) domain.User {
	if st.ParentUserID == "" {
		return domain.User{}
	}
	u, _ := s.db(c).UserByID(st.ParentUserID)
	return u
}

// deref returns the pointed-to string, or "" for nil.
func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
