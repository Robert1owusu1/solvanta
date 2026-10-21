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
		if a.Audience == domain.AudClasses && s.viewsClass(u, a.TargetClassID) {
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
	if writeFailed(c, s.store.AddAnnouncement(a)) {
		return
	}
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
	for i := range out {
		out[i].State = messageState(out[i])
	}
	sendJSON(c, out)
}

// messageState is the receipt the client renders: sent until the
// recipient's device reports delivery, then read once they open it.
func messageState(m domain.Message) string {
	switch {
	case m.Read || m.ReadAt != "":
		return "read"
	case m.DeliveredAt != "":
		return "delivered"
	}
	return "sent"
}

type receiptRequest struct {
	State string `json:"state"`
}

// messageReceipt records that the recipient's device delivered or opened a
// message. Only the recipient may report it; stamps never move once set.
func (s *Server) messageReceipt(c *gin.Context) {
	u := currentUser(c)
	var body receiptRequest
	if !bind(c, &body) {
		return
	}
	var found *domain.Message
	for _, m := range s.store.Messages() {
		if m.ID == c.Param("id") {
			m := m
			found = &m
			break
		}
	}
	if found == nil {
		fail(c, http.StatusNotFound, "Message not found")
		return
	}
	if found.ToID != u.ID {
		fail(c, http.StatusForbidden, "Only the recipient can acknowledge a message")
		return
	}
	at := now()
	switch body.State {
	case "delivered":
		if writeFailed(c, s.store.SetMessageReceipt(found.ID, at, "")) {
			return
		}
	case "read":
		if writeFailed(c, s.store.SetMessageReceipt(found.ID, at, at)) {
			return
		}
	default:
		fail(c, http.StatusBadRequest, "state must be delivered or read")
		return
	}
	sendJSON(c, gin.H{"id": found.ID, "state": body.State})
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
	if writeFailed(c, s.store.SaveMessage(m)) {
		return
	}
	s.notify(body.ToID, domain.NotifMessage, body.Subject, body.Body, body.RelatedStudentID)
	s.audit(c, "message.send", m.ID, "Message from "+u.Name, "")
	sendCreated(c, m)
}

// notificationAllowed mirrors the visibility rules for notifications:
//   - addressed to a user → only that user;
//   - student-scoped (no user) → the student's parents (and super admins);
//   - unaddressed → everyone.
//
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

// notificationsFor returns the notifications u may see, with Read reporting
// u's own read state: an addressed notification has one reader, so its row
// flag is theirs; a student-scoped one is read per reader.
func (s *Server) notificationsFor(u domain.User) []domain.Notification {
	reads := s.store.NotificationReadsBy(u.ID)
	out := []domain.Notification{}
	for _, n := range s.store.Notifications() {
		if !notificationAllowed(u, n) {
			continue
		}
		if n.UserID == "" {
			n.Read = reads[n.ID]
		}
		out = append(out, n)
	}
	return out
}

// markRead records that u read n (see notificationsFor).
func (s *Server) markRead(u domain.User, n domain.Notification) error {
	if n.UserID != "" {
		return s.store.SetNotificationRead(n.ID)
	}
	return s.store.MarkNotificationReadBy(n.ID, u.ID)
}

// unreadNotifications returns notifications visible to the user that haven't
// been read yet.
func (s *Server) unreadNotifications(c *gin.Context) {
	out := []domain.Notification{}
	for _, n := range s.notificationsFor(currentUser(c)) {
		if !n.Read {
			out = append(out, n)
		}
	}
	sendJSON(c, out)
}

func (s *Server) markNotificationRead(c *gin.Context) {
	u := currentUser(c)
	id := c.Param("id")
	var found *domain.Notification
	for _, n := range s.store.Notifications() {
		if n.ID == id {
			if !notificationAllowed(u, n) {
				fail(c, http.StatusForbidden, "Not your notification")
				return
			}
			n := n
			found = &n
			break
		}
	}
	if found == nil {
		fail(c, http.StatusNotFound, "Notification not found")
		return
	}
	if writeFailed(c, s.markRead(u, *found)) {
		return
	}
	sendJSON(c, gin.H{"read": id})
}

func (s *Server) markAllNotificationsRead(c *gin.Context) {
	u := currentUser(c)
	count := 0
	for _, n := range s.notificationsFor(u) {
		if n.Read {
			continue
		}
		if writeFailed(c, s.markRead(u, n)) {
			return
		}
		count++
	}
	sendJSON(c, gin.H{"marked": count})
}
