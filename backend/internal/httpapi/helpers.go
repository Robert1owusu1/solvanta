package httpapi

import (
	"fmt"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// newID builds a short unique id with the given prefix.
func newID(prefix string) string {
	return fmt.Sprintf("%s-%d-%d", prefix, time.Now().Unix(), time.Now().Nanosecond()%100000)
}

// now returns a compact local timestamp string.
func now() string { return time.Now().Format("2006-01-02T15:04") }

// today returns the YYYY-MM-DD date.
func today() string { return time.Now().Format("2006-01-02") }

// audit records an action against the audit log (doc §49).
func (s *Server) audit(c *gin.Context, action, target, detail, reason string) {
	u := currentUser(c)
	s.store.AddAudit(domain.AuditEntry{
		ID:        newID("AUD"),
		Action:    action,
		Actor:     u.Name,
		Target:    target,
		Detail:    detail,
		Timestamp: now(),
		Reason:    reason,
	})
}

// notify fans out a notification to the given user id (prepended, newest
// first, matching the app's notification ordering).
func (s *Server) notify(userID, kind, title, body, studentID string) {
	s.store.AddNotification(domain.Notification{
		ID:        newID("NOTIF"),
		Kind:      kind,
		Title:     title,
		Body:      body,
		Timestamp: now(),
		StudentID: studentID,
		UserID:    userID,
	})
}
