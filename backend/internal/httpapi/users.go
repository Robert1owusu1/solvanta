package httpapi

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// listUsers returns the school's accounts (password hashes are never exposed).
func (s *Server) listUsers(c *gin.Context) {
	u := currentUser(c)
	var out []domain.User
	for _, x := range s.store.Users() {
		if x.Role == domain.RoleSuperAdmin && !u.IsSuperAdmin() {
			continue
		}
		if u.IsSuperAdmin() || x.SchoolID == "" || x.SchoolID == u.SchoolID {
			x.Password = ""
			out = append(out, x)
		}
	}
	sendJSON(c, out)
}

type createUserRequest struct {
	Name       string   `json:"name"`
	Email      string   `json:"email"`
	Phone      string   `json:"phone"`
	Password   string   `json:"password"`
	Role       string   `json:"role"`
	ClassID    string   `json:"classId"`
	SchoolID   string   `json:"schoolId"`
	StudentIDs []string `json:"studentIds"`
}

// createUser provisions an account (doc §9) with a hashed password and
// validated inputs. Only superAdmins and schoolAdmins may create users.
func (s *Server) createUser(c *gin.Context) {
	u := currentUser(c)
	var body createUserRequest
	if !bind(c, &body) {
		return
	}
	body.Email = strings.ToLower(strings.TrimSpace(body.Email))
	body.Name = strings.TrimSpace(body.Name)
	if body.Name == "" {
		fail(c, http.StatusBadRequest, "name is required")
		return
	}
	if !validEmail(body.Email) {
		fail(c, http.StatusBadRequest, "invalid email address")
		return
	}
	if msg := checkPasswordPolicy(body.Password); msg != "" {
		fail(c, http.StatusBadRequest, "weak password: "+msg)
		return
	}
	if !validRole(body.Role) {
		fail(c, http.StatusBadRequest, "unknown role")
		return
	}
	if body.Role == domain.RoleSuperAdmin && !u.IsSuperAdmin() {
		fail(c, http.StatusForbidden, "only the super admin can create super admins")
		return
	}
	if _, exists := s.store.UserByEmail(body.Email); exists {
		fail(c, http.StatusConflict, "A user with this email already exists")
		return
	}
	schoolID := body.SchoolID
	if !u.IsSuperAdmin() {
		if u.SchoolID == "" {
			fail(c, http.StatusForbidden, "no school bound to this account")
			return
		}
		schoolID = u.SchoolID
	}
	if body.Role == domain.RoleParent || body.Role == domain.RoleStudent {
		if len(body.StudentIDs) == 0 && body.ClassID == "" {
			fail(c, http.StatusBadRequest, "link the account to a student (studentIds) or class (classId)")
			return
		}
	}
	nu := domain.User{
		ID:         newID("USR"),
		Name:       body.Name,
		Email:      body.Email,
		Phone:      body.Phone,
		Password:   hashPassword(body.Password),
		Role:       body.Role,
		SchoolID:   schoolID,
		ClassID:    body.ClassID,
		StudentIDs: body.StudentIDs,
	}
	if writeFailed(c, s.store.SaveUser(nu)) {
		return
	}
	s.audit(c, "user.create", nu.ID, "Created "+nu.Role+" account "+nu.Name, "")
	nu.Password = ""
	sendCreated(c, nu)
}

type passwordChangeRequest struct {
	Current string `json:"current"`
	New     string `json:"new"`
}

// changePassword lets any authenticated user rotate their own password after
// verifying the current one (doc §9 security).
func (s *Server) changePassword(c *gin.Context) {
	var body passwordChangeRequest
	if !bind(c, &body) {
		return
	}
	targetID := c.Param("id")
	u := currentUser(c)
	if targetID != u.ID {
		fail(c, http.StatusForbidden, "You may only change your own password")
		return
	}
	if !verifyPassword(u.Password, body.Current) {
		fail(c, http.StatusUnauthorized, "Current password is incorrect")
		return
	}
	if msg := checkPasswordPolicy(body.New); msg != "" {
		fail(c, http.StatusBadRequest, "weak password: "+msg)
		return
	}
	if body.New == body.Current {
		fail(c, http.StatusBadRequest, "new password must differ from the current one")
		return
	}
	u.Password = hashPassword(body.New)
	if writeFailed(c, s.store.SaveUser(u)) {
		return
	}
	s.audit(c, "user.password", u.ID, "Password changed", "")
	// revoke all outstanding sessions for this account
	if tc, ok := s.claimsFromRequest(c); ok {
		s.revoke(tc.Jti, tcExpiry(tc))
	}
	sendJSON(c, gin.H{"status": "password_changed"})
}

type passwordResetRequest struct {
	New string `json:"new"`
}

// resetPassword lets an administrator set a new password for an account in
// their school, for a user who has forgotten theirs. Every session the
// account holds is signed out.
func (s *Server) resetPassword(c *gin.Context) {
	u := currentUser(c)
	target, ok := s.store.UserByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "User not found")
		return
	}
	if !u.IsSuperAdmin() && (target.Role == domain.RoleSuperAdmin || target.SchoolID != u.SchoolID) {
		fail(c, http.StatusForbidden, "You may only reset passwords in your school")
		return
	}
	var body passwordResetRequest
	if !bind(c, &body) {
		return
	}
	if msg := checkPasswordPolicy(body.New); msg != "" {
		fail(c, http.StatusBadRequest, "weak password: "+msg)
		return
	}
	target.Password = hashPassword(body.New)
	if writeFailed(c, s.store.SaveUser(target)) {
		return
	}
	if writeFailed(c, s.store.DeleteRefreshTokensForUser(target.ID)) {
		return
	}
	s.audit(c, "user.password_reset", target.ID, "Reset the password of "+target.Name, "")
	sendJSON(c, gin.H{"status": "password_reset"})
}
