package httpapi

import (
	"net/http"
	"sort"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

func (s *Server) listAnnouncements(c *gin.Context) {
	u := currentUser(c)
	all := s.store.Announcements()
	if u.IsSchoolStaff() {
		sendJSON(c, all)
		return
	}
	var visible []domain.Announcement
	for _, a := range all {
		if a.Audience == domain.AudSchool || a.Audience == domain.AudEmergency {
			visible = append(visible, a)
			continue
		}
		if a.Audience == domain.AudClasses && a.TargetClassID == s.viewClassID(u) {
			visible = append(visible, a)
		}
	}
	sendJSON(c, visible)
}

type announcementRequest struct {
	Title         string `json:"title"`
	Body          string `json:"body"`
	Audience      string `json:"audience"`
	TargetClassID string `json:"targetClassId"`
}

func (s *Server) createAnnouncement(c *gin.Context) {
	u := currentUser(c)
	var body announcementRequest
	if !bind(c, &body) {
		return
	}
	aud := body.Audience
	if aud != domain.AudClasses && aud != domain.AudEmergency {
		aud = domain.AudSchool
	}
	a := domain.Announcement{
		ID:            newID("ANN"),
		Title:         body.Title,
		Body:          body.Body,
		Audience:      aud,
		TargetClassID: body.TargetClassID,
		AuthorID:      u.ID,
		AuthorName:    u.Name,
		Timestamp:     now(),
	}
	s.store.AddAnnouncement(a)
	// fan out to parents of the target class
	targets := map[string]bool{}
	for _, st := range s.store.Students() {
		if body.TargetClassID != "" && st.ClassID != body.TargetClassID {
			continue
		}
		if st.ParentUserID != "" {
			targets[st.ParentUserID] = true
		}
	}
	for pid := range targets {
		s.notify(pid, domain.NotifAnnouncement, a.Title, a.Body, "")
	}
	s.audit(c, "announcement.create", a.ID, "Announced to "+aud+": "+a.Title, "")
	sendCreated(c, a)
}

// listMessages returns messages where the user is sender or recipient,
// newest first (doc §40).
func (s *Server) listMessages(c *gin.Context) {
	u := currentUser(c)
	var out []domain.Message
	for _, m := range s.store.Messages() {
		if m.FromID == u.ID || m.ToID == u.ID {
			out = append(out, m)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[j].Timestamp < out[i].Timestamp })
	sendJSON(c, out)
}

type messageRequest struct {
	ToID             string `json:"toId"`
	Subject          string `json:"subject"`
	Body             string `json:"body"`
	RelatedStudentID string `json:"relatedStudentId"`
}

func (s *Server) sendMessage(c *gin.Context) {
	u := currentUser(c)
	var body messageRequest
	if !bind(c, &body) {
		return
	}
	if _, ok := s.store.UserByID(body.ToID); !ok {
		fail(c, http.StatusNotFound, "Recipient not found")
		return
	}
	if body.RelatedStudentID != "" {
		if _, ok := s.store.StudentByID(body.RelatedStudentID); !ok {
			fail(c, http.StatusNotFound, "Related student not found")
			return
		}
	}
	m := domain.Message{
		ID: newID("MSG"), FromID: u.ID, ToID: body.ToID,
		RelatedStudentID: body.RelatedStudentID,
		Subject:          body.Subject, Body: body.Body, Timestamp: now(),
	}
	s.store.SaveMessage(m)
	s.notify(body.ToID, domain.NotifMessage, body.Subject, body.Body, body.RelatedStudentID)
	s.audit(c, "message.send", m.ID, "Message from "+u.Name, "")
	sendCreated(c, m)
}

// notificationAllowed mirrors the visibility rules for notifications:
//   - addressed to a user → only that user;
//   - student-scoped (no user) → the student's parents (and super admins);
//   - unaddressed → everyone.
// Used by both unread listing and read-state mutations so a user can never
// act on a notification they cannot see.
func notificationAllowed(u domain.User, n domain.Notification) bool {
	if n.UserID != "" {
		return n.UserID == u.ID
	}
	if n.StudentID != "" {
		if u.IsSuperAdmin() {
			return true
		}
		switch u.Role {
		case domain.RoleParent:
			for _, id := range u.StudentIDs {
				if id == n.StudentID {
					return true
				}
			}
			return false
		case domain.RoleStudent:
			// a pupil sees notifications about their own record, never a
			// classmate's
			return stringToStudentID(u.ID) == n.StudentID
		}
		return false
	}
	return true
}

// unreadNotifications returns notifications visible to the user that haven't
// been read yet.
func (s *Server) unreadNotifications(c *gin.Context) {
	u := currentUser(c)
	var out []domain.Notification
	for _, n := range s.store.Notifications() {
		if !notificationAllowed(u, n) || n.Read {
			continue
		}
		out = append(out, n)
	}
	sendJSON(c, out)
}

func (s *Server) markNotificationRead(c *gin.Context) {
	u := currentUser(c)
	id := c.Param("id")
	found := false
	for _, n := range s.store.Notifications() {
		if n.ID == id {
			found = true
			if !notificationAllowed(u, n) {
				fail(c, http.StatusForbidden, "Not your notification")
				return
			}
			break
		}
	}
	if !found {
		fail(c, http.StatusNotFound, "Notification not found")
		return
	}
	s.store.SetNotificationRead(id)
	sendJSON(c, gin.H{"read": id})
}

func (s *Server) markAllNotificationsRead(c *gin.Context) {
	u := currentUser(c)
	count := 0
	for _, n := range s.store.Notifications() {
		if !notificationAllowed(u, n) || n.Read {
			continue
		}
		s.store.SetNotificationRead(n.ID)
		count++
	}
	sendJSON(c, gin.H{"marked": count})
}
