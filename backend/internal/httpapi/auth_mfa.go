package httpapi

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/security"
)

// Two-factor authentication (TOTP). Enrolment is a logged-in action; at sign-in
// a user with MFA on gets a short-lived challenge (see login) that this file's
// /auth/mfa/verify exchanges for a real session once they enter their code.

// mfaSetup starts enrolment: it mints a secret (not yet active) and returns it
// with the otpauth URI the authenticator app scans. Enrolment is confirmed by
// mfaEnable with a valid code.
func (s *Server) mfaSetup(c *gin.Context) {
	u := currentUser(c)
	if u.MFAEnabled {
		fail(c, http.StatusConflict, "Two-factor is already on for this account")
		return
	}
	u.MFASecret = security.GenerateTOTPSecret()
	if writeFailed(c, s.db(c).SaveUser(u)) {
		return
	}
	sendJSON(c, gin.H{
		"secret":     u.MFASecret,
		"otpauthUri": security.TOTPURI("SOLVANTA", u.Email, u.MFASecret),
	})
}

type mfaCodeRequest struct {
	Code string `json:"code"`
}

// mfaEnable confirms enrolment: the code must match the secret from mfaSetup.
func (s *Server) mfaEnable(c *gin.Context) {
	u := currentUser(c)
	var body mfaCodeRequest
	if !bind(c, &body) {
		return
	}
	if u.MFASecret == "" {
		fail(c, http.StatusBadRequest, "Start setup first")
		return
	}
	if !security.VerifyTOTP(u.MFASecret, strings.TrimSpace(body.Code), time.Now()) {
		fail(c, http.StatusBadRequest, "That code is not valid. Try the current one.")
		return
	}
	u.MFAEnabled = true
	if writeFailed(c, s.db(c).SaveUser(u)) {
		return
	}
	s.audit(c, "auth.mfa.enable", u.ID, "Two-factor turned on", "")
	sendJSON(c, gin.H{"enabled": true})
}

// mfaDisable turns two-factor off, requiring a current code so a walk-up on an
// unlocked device cannot remove it.
func (s *Server) mfaDisable(c *gin.Context) {
	u := currentUser(c)
	var body mfaCodeRequest
	if !bind(c, &body) {
		return
	}
	if !u.MFAEnabled {
		sendJSON(c, gin.H{"enabled": false})
		return
	}
	if !security.VerifyTOTP(u.MFASecret, strings.TrimSpace(body.Code), time.Now()) {
		fail(c, http.StatusBadRequest, "That code is not valid.")
		return
	}
	u.MFAEnabled = false
	u.MFASecret = ""
	if writeFailed(c, s.db(c).SaveUser(u)) {
		return
	}
	s.audit(c, "auth.mfa.disable", u.ID, "Two-factor turned off", "")
	sendJSON(c, gin.H{"enabled": false})
}

// mfaVerify is the second sign-in step: it accepts the challenge token from
// login plus the one-time code, and on success issues a full session token.
func (s *Server) mfaVerify(c *gin.Context) {
	var body struct {
		MFAToken string `json:"mfaToken"`
		Code     string `json:"code"`
	}
	if !bind(c, &body) {
		return
	}
	tc, ok := s.parseToken(body.MFAToken)
	if !ok || !tc.Mfa {
		fail(c, http.StatusUnauthorized, "Your sign-in session expired. Start again.")
		return
	}
	home, err := s.tenants.For(tc.Sch)
	if err != nil {
		fail(c, http.StatusUnauthorized, "Unknown school")
		return
	}
	u, ok := home.UserByID(tc.Sub)
	if !ok || !u.MFAEnabled {
		fail(c, http.StatusUnauthorized, "Two-factor is not active for this account")
		return
	}
	if !security.VerifyTOTP(u.MFASecret, strings.TrimSpace(body.Code), time.Now()) {
		fail(c, http.StatusUnauthorized, "That code is not valid. Try the current one.")
		return
	}
	c.Set(ctxStoreKey, home)
	s.audit(c, "auth.login", u.ID, "Signed in as "+u.Name+" (2FA)", "")
	sendJSON(c, gin.H{"token": s.sign(u, tokenTTL), "user": u})
}
