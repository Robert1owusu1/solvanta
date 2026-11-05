package httpapi

import (
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// Self-service password reset. forgotPassword emails a short-lived reset token;
// resetPassword exchanges it (plus a new password) for a changed password. The
// token is one-time (revoked after use) and only /auth/password/reset accepts
// it. forgotPassword always answers the same way so it never reveals whether an
// email is registered.

func (s *Server) forgotPassword(c *gin.Context) {
	var body struct {
		Email string `json:"email"`
	}
	if !bind(c, &body) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))
	if u, home, ok := s.userByEmail(email); ok && email != "" {
		token := s.signReset(u)
		msg := "Hello " + u.Name + ",\n\n" +
			"We received a request to reset your SOLVANTA password. Open the app, " +
			"go to the reset screen, and paste this code:\n\n" + token + "\n\n" +
			"It expires in 30 minutes. If you didn't ask for this, ignore this email."
		if err := s.email.Send(c.Request.Context(), u.Email, "Reset your SOLVANTA password", msg); err != nil {
			log.Printf("password reset email to %s failed: %v", u.Email, err)
		}
		// Without a configured mailer the code is only useful if it is visible,
		// so log it in that (dev) mode. Never logged once real email is set up.
		if s.email.Name() == "log" {
			log.Printf("[dev] password reset code for %s: %s", u.Email, token)
		}
		c.Set(ctxStoreKey, home)
		s.audit(c, "auth.password.forgot", u.ID, "Password reset requested", "")
	}
	sendJSON(c, gin.H{"status": "ok"})
}

func (s *Server) selfResetPassword(c *gin.Context) {
	var body struct {
		Token       string `json:"token"`
		NewPassword string `json:"newPassword"`
	}
	if !bind(c, &body) {
		return
	}
	tc, ok := s.parseToken(strings.TrimSpace(body.Token))
	if !ok || !tc.Reset || s.isRevoked(tc.Jti) {
		fail(c, http.StatusBadRequest, "This reset link is invalid or has expired. Request a new one.")
		return
	}
	if msg := checkPasswordPolicy(body.NewPassword); msg != "" {
		fail(c, http.StatusBadRequest, "weak password: "+msg)
		return
	}
	home, err := s.tenants.For(tc.Sch)
	if err != nil {
		fail(c, http.StatusBadRequest, "This reset link is no longer valid.")
		return
	}
	u, ok := home.UserByID(tc.Sub)
	if !ok {
		fail(c, http.StatusBadRequest, "This reset link is no longer valid.")
		return
	}
	u.Password = hashPassword(body.NewPassword)
	if writeFailed(c, home.SaveUser(u)) {
		return
	}
	// One-time use: the reset token can't be replayed.
	s.revoke(tc.Jti, time.Unix(tc.Exp, 0))
	c.Set(ctxStoreKey, home)
	s.audit(c, "auth.password.reset", u.ID, "Password reset", "")
	sendJSON(c, gin.H{"status": "ok"})
}
