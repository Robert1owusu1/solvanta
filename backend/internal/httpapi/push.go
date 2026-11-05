package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// registerPushToken stores the signed-in user's device push token so remote
// notifications can reach it. One record per token (id derived from the token),
// owner-scoped, so re-registering the same device is idempotent and a user only
// ever touches their own tokens.
//
// POST /api/push/register  { "token": "...", "platform": "android|ios|web" }
func (s *Server) registerPushToken(c *gin.Context) {
	u := currentUser(c)
	var body struct {
		Token    string `json:"token"`
		Platform string `json:"platform"`
	}
	if !bind(c, &body) {
		return
	}
	body.Token = strings.TrimSpace(body.Token)
	if body.Token == "" {
		fail(c, http.StatusBadRequest, "token is required")
		return
	}
	sum := sha256.Sum256([]byte(body.Token))
	id := "PUSH-" + hex.EncodeToString(sum[:])[:24]
	data, _ := json.Marshal(gin.H{"token": body.Token, "platform": body.Platform})
	rec := domain.Record{
		Kind:      domain.RecordPushTokens,
		ID:        id,
		OwnerID:   u.ID,
		UpdatedAt: now(),
		Data:      data,
	}
	if writeFailed(c, s.db(c).SaveRecord(rec)) {
		return
	}
	sendJSON(c, gin.H{"registered": true})
}
