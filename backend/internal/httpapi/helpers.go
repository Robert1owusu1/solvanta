package httpapi

import (
	"fmt"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// intIDBase seeds a strictly monotonic id sequence shared by newID and
// newIntID. Seeded from the clock at process start so a restart cannot re-issue
// ids minted by a previous run.
var intIDBase = time.Now().UnixNano()

// newIntID mints a process-unique positive int64 for rows whose tables use
// BIGSERIAL primary keys (accepted answers, misconceptions).
//
// The SERVER owns these ids. Accepting the client's is unsafe: clients number
// answers per question (1, 2, 3 …, or 1001, 1002 …), so two unrelated schemes
// send the same id — and because both stores upsert ON CONFLICT (id), the
// second save would silently overwrite and re-parent the first scheme's rows.
func newIntID() int64 {
	return atomic.AddInt64(&intIDBase, 1)
}

// newID builds a short unique id with the given prefix.
//
// The clock alone is NOT a unique source. On coarse-timer platforms (Windows
// ticks at ~15ms) two calls inside the same tick return identical values —
// which minted duplicate primary keys. It broke the marking-scheme version
// chain deterministically: a fork created in the same tick as its parent
// reused the parent's id, so the upsert overwrote v1 instead of creating v2,
// destroying the version that submissions were graded against.
//
// The counter supplies within-process uniqueness; the clock seed supplies
// across-restart uniqueness. `prefix` is still the readable, greppable part.
func newID(prefix string) string {
	return fmt.Sprintf("%s-%d", prefix, newIntID())
}

// newQuestionID mints a unique TEXT id for a scheme_questions row, for the same
// reason newIntID exists: client-generated question ids ("SQ-1", "SQ-2") are
// only unique within one scheme, while scheme_questions.id is a global
// primary key that both stores upsert on.
func newQuestionID() string {
	return fmt.Sprintf("SQ-%d", newIntID())
}

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

// now returns a compact local timestamp string, in the 'yyyy-MM-dd HH:mm'
// form the client and the seed use.
func now() string { return time.Now().Format("2006-01-02 15:04") }

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
	s.db(c).AddAudit(domain.AuditEntry{
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
func (s *Server) notify(c *gin.Context, userID, kind, title, body, studentID string) {
	s.db(c).AddNotification(domain.Notification{
		ID:        newID("NOTIF"),
		Kind:      kind,
		Title:     title,
		Body:      body,
		Timestamp: now(),
		StudentID: studentID,
		UserID:    userID,
	})
}
