package httpapi

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

// login authenticates against a bcrypt hash and issues a signed bearer token.
// Unknown emails still pay a bcrypt compare so timing does not reveal which
// accounts exist. Password plaintext comparison only exists in the demo seed
// path and is never used here.
func (s *Server) login(c *gin.Context) {
	var req loginRequest
	if !bind(c, &req) {
		return
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if req.Email == "" || req.Password == "" {
		fail(c, http.StatusBadRequest, "email and password are required")
		return
	}

	u, ok := s.store.UserByEmail(req.Email)
	if !ok {
		// burn a bcrypt compare so account existence isn't timing-visible
		burnCandidate(req.Password)
		fail(c, http.StatusUnauthorized, "Invalid email or password")
		return
	}
	if !verifyPassword(u.Password, req.Password) {
		fail(c, http.StatusUnauthorized, "Invalid email or password")
		return
	}
	s.audit(c, "auth.login", u.ID, "Signed in as "+u.Name, "")
	sendJSON(c, gin.H{"token": s.sign(u, tokenTTL), "user": u})
}

// logout revokes the presented token for the rest of its lifetime.
func (s *Server) logout(c *gin.Context) {
	if tc, ok := s.claimsFromRequest(c); ok {
		s.revoke(tc.Jti, time.Unix(tc.Exp, 0))
	}
	sendJSON(c, gin.H{"status": "logged_out"})
}

// updateSchool edits the school profile (doc §8).
func (s *Server) updateSchool(c *gin.Context) {
	var body domain.School
	if !bind(c, &body) {
		return
	}
	if body.ID == "" {
		body.ID = domain.DefaultSchoolID()
	}
	old := s.store.School()
	if old.ID != "" && body.ID == old.ID {
		body.Name, body.Motto, body.Address, body.Phone, body.Email, body.Region =
			firstNonEmpty(body.Name, old.Name), firstNonEmpty(body.Motto, old.Motto),
			firstNonEmpty(body.Address, old.Address), firstNonEmpty(body.Phone, old.Phone),
			firstNonEmpty(body.Email, old.Email), firstNonEmpty(body.Region, old.Region)
	}
	if writeFailed(c, s.store.SaveSchool(body)) {
		return
	}
	s.audit(c, "school.update", body.ID, "School profile updated", "")
	sendJSON(c, body)
}

// updateTerm edits the current academic term (doc §19).
func (s *Server) updateTerm(c *gin.Context) {
	var body domain.SchoolTerm
	if !bind(c, &body) {
		return
	}
	old := s.store.Term()
	u := currentUser(c)
	body = domain.SchoolTerm{
		Year:  firstNonEmpty(body.Year, old.Year),
		Name:  firstNonEmpty(body.Name, old.Name),
		Start: firstNonEmpty(body.Start, old.Start),
		End:   firstNonEmpty(body.End, old.End),
	}
	if writeFailed(c, s.store.SaveTerm(body)) {
		return
	}
	// A new term that starts after the old one ended closes the old one:
	// keep it with the grading it was awarded under. Correcting the current
	// term's dates closes nothing.
	if old.End != "" && old.End < body.Start {
		school := s.userSchool(u)
		grading, ok := s.store.GradingConfig(school)
		if !ok {
			grading = domain.DefaultGradingConfig(school)
		}
		if writeFailed(c, s.store.SaveFinishedTerm(school, domain.FinishedTerm{SchoolTerm: old, Grading: grading})) {
			return
		}
	}
	s.audit(c, "term.update", body.Label(), "Academic term updated", "")
	sendJSON(c, body)
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
