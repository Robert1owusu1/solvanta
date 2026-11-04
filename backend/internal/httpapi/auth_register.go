package httpapi

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

type registerRequest struct {
	Name                 string `json:"name"`
	Email                string `json:"email"`
	Phone                string `json:"phone"`
	Password             string `json:"password"`
	WorkspaceName        string `json:"workspaceName"`
	Independent          bool   `json:"independent"`
	AcceptDataProtection bool   `json:"acceptDataProtection"`
}

// register is public self-registration for an independent teacher. It creates a
// brand-new tenant (schema-per-tenant isolation), owned by the teacher, with
// school.kind = independent — rather than dropping every self-registered
// teacher into the default school, which was a data-isolation bug.
//
// The teacher owns the workspace and holds schoolAdmin rights inside it (so
// they can create their own classes, students and assessments); the capability
// layer keyed on school.kind keeps the workspace out of the school-only
// modules. On transfer into a real school they become a normal teacher.
func (s *Server) register(c *gin.Context) {
	var body registerRequest
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
	if !body.Independent {
		// Only the independent-teacher path is a server registration; joining an
		// existing school is done by that school's admin creating the account.
		fail(c, http.StatusBadRequest, "only independent teacher registration is supported here")
		return
	}
	// Children's data is being registered, so the notice must be accepted first.
	if !body.AcceptDataProtection {
		fail(c, http.StatusBadRequest, "you must accept the data-protection notice to register")
		return
	}
	if _, _, exists := s.userByEmail(body.Email); exists {
		fail(c, http.StatusConflict, "A user with this email already exists")
		return
	}

	// A private workspace id nobody else holds.
	var workspaceID string
	for i := 0; i < 5; i++ {
		candidate := "WS-" + randomHex(8)
		if _, err := s.tenants.For(candidate); err != nil {
			workspaceID = candidate
			break
		}
	}
	if workspaceID == "" {
		fail(c, http.StatusInternalServerError, "Could not create your workspace. Please try again.")
		return
	}
	st, err := s.tenants.Create(workspaceID)
	if err != nil {
		fail(c, http.StatusInternalServerError, "Could not create your workspace. Please try again.")
		return
	}

	userID := newID("USR")
	workspaceName := firstNonEmpty(strings.TrimSpace(body.WorkspaceName), body.Name+"'s workspace")
	school := domain.School{
		ID:                       workspaceID,
		Name:                     workspaceName,
		Kind:                     domain.SchoolKindIndependent,
		OwnerUserID:              userID,
		DataProtectionAcceptedAt: now(),
	}
	if writeFailed(c, st.SaveSchool(school)) {
		return
	}
	nu := domain.User{
		ID:       userID,
		Name:     body.Name,
		Email:    body.Email,
		Phone:    strings.TrimSpace(body.Phone),
		Password: hashPassword(body.Password),
		// Owner of their own tenant: schoolAdmin rights inside it. A transfer
		// later downgrades this to teacher in the destination school.
		Role:     domain.RoleSchoolAdmin,
		SchoolID: workspaceID,
	}
	if writeFailed(c, st.SaveUser(nu)) {
		return
	}

	c.Set(ctxStoreKey, st)
	s.audit(c, "auth.register", nu.ID,
		"Independent teacher "+nu.Name+" registered workspace "+workspaceID, "")
	sendCreated(c, gin.H{"token": s.sign(nu, tokenTTL), "user": nu, "schoolId": workspaceID})
}
