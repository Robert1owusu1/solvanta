package httpapi

import (
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// writeFailed reports a failed store write as a 500 and tells the caller to
// stop. The store has already recorded the detail (Postgres.errLog, surfaced
// on /health as storageErrors), so the client gets a generic message and no
// SQL, table or constraint name leaves the process. A handler that skips this
// would answer 200 for a row that was never written — the exact failure this
// project spent a whole workstream removing.
func writeFailed(c *gin.Context, err error) bool {
	if err == nil {
		return false
	}
	fail(c, http.StatusInternalServerError, "Could not save your changes. Please try again.")
	return true
}

// newID builds a short unique id with the given prefix.
func newID(prefix string) string {
	return fmt.Sprintf("%s-%d-%d", prefix, time.Now().Unix(), time.Now().Nanosecond()%100000)
}

// now returns a compact local timestamp string.
func now() string { return time.Now().Format("2006-01-02T15:04") }

// today returns the YYYY-MM-DD date.
func today() string { return time.Now().Format("2006-01-02") }

// isISODate reports whether s is a real 'yyyy-MM-dd' calendar date. Checked
// here rather than left to the database so both stores answer the same way:
// the memory store would happily keep "next Tuesday" as a date string where
// PostgreSQL rejects it, and a validation error that depends on which store is
// configured is a bug nobody can reproduce.
func isISODate(s string) bool {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {
		return false
	}
	_, err := time.Parse("2006-01-02", s)
	return err == nil
}

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
