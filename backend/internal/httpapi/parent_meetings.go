package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// meetingFields are the parts of a parent meeting the rules look at.
type meetingFields struct {
	Status       string `json:"status"`
	Reason       string `json:"reason"`
	ScheduledFor string `json:"scheduledFor"`
	Place        string `json:"place"`
	Outcome      string `json:"outcome"`
}

var meetingStatuses = map[string]bool{
	"requested": true, "scheduled": true, "held": true, "cancelled": true,
}

// checkParentMeeting keeps a meeting well-formed and tells the family when
// one is booked (or re-booked to another time).
func checkParentMeeting(s *Server, c *gin.Context, u domain.User, prev *domain.Record, next *domain.Record) bool {
	var n, p meetingFields
	_ = json.Unmarshal(next.Data, &n)
	if prev != nil {
		_ = json.Unmarshal(prev.Data, &p)
	}
	switch {
	case !meetingStatuses[n.Status]:
		fail(c, http.StatusBadRequest, "status must be requested, scheduled, held or cancelled")
		return false
	case n.Status == "scheduled" && n.ScheduledFor == "":
		fail(c, http.StatusBadRequest, "a scheduled meeting needs a date and time")
		return false
	case len(n.Reason) > maxRemark || len(n.Outcome) > 2000 || len(n.Place) > 120:
		fail(c, http.StatusBadRequest, "meeting text is too long")
		return false
	}
	if n.Status == "scheduled" && (p.Status != "scheduled" || p.ScheduledFor != n.ScheduledFor) {
		where := ""
		if n.Place != "" {
			where = " at " + n.Place
		}
		s.notify(c, "", domain.NotifMeeting, "Meeting with the school: "+n.ScheduledFor,
			"The school would like to meet you on "+n.ScheduledFor+where+" about your child's progress.",
			next.StudentID)
		s.textFamily(c, next.StudentID, smsMeeting,
			schoolLabel(s.db(c))+": please meet us on "+n.ScheduledFor+where+" about your child's progress.")
	}
	return true
}
