package httpapi

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// gateEvents lists gate events (newest first), optionally filtered by date.
func (s *Server) gateEvents(c *gin.Context) {
	date := c.Query("date")
	var out []domain.GateEvent
	for _, e := range s.store.GateEvents() {
		if date == "" || e.Date == date {
			out = append(out, e)
		}
	}
	sendJSON(c, out)
}

type gateEventRequest struct {
	StudentID string `json:"studentId"`
	Type      string `json:"type"`
	Time      string `json:"time"`
	Date      string `json:"date"`
	Reporter  string `json:"reporter"`
	Person    string `json:"person"`
	Detail    string `json:"detail"`
}

// createGateEvent records an arrival/departure/pickup event and, on unsafe
// types, notifies the parent (doc §13, §36).
func (s *Server) createGateEvent(c *gin.Context) {
	var body gateEventRequest
	if !bind(c, &body) {
		return
	}
	st, ok := s.store.StudentByID(body.StudentID)
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	u := currentUser(c)
	ev := domain.GateEvent{
		ID:        newID("GATE"),
		StudentID: st.ID,
		Type:      body.Type,
		Time:      firstNonEmpty(body.Time, now()[11:16]),
		Date:      firstNonEmpty(body.Date, today()),
		Reporter:  firstNonEmpty(body.Reporter, u.Name),
		Person:    body.Person,
		Detail:    body.Detail,
	}
	s.store.AddGateEvent(ev)
	s.audit(c, "gate.update", ev.ID, "Gate event "+ev.Type+" for "+st.FullName(), body.Detail)

	if p := userForStudent(s, st); p.ID != "" {
		switch ev.Type {
		case domain.GateUnauthorizedPickup:
			s.notify(p.ID, domain.NotifGate, "Unverified pickup attempt for "+st.FullName(),
				"Someone not on the authorized list attempted pickup at "+ev.Time+". Please verify. Contact the school immediately.", st.ID)
		case domain.GateEarlyDeparture:
			s.notify(p.ID, domain.NotifGate, st.FullName()+" left school early",
				"Early departure recorded at "+ev.Time+": "+ev.Detail, st.ID)
		case domain.GateDeparture:
			s.notify(p.ID, domain.NotifGate, st.FullName()+" left school",
				st.FullName()+" departed at "+ev.Time+".", st.ID)
		}
	}
	sendCreated(c, ev)
}

// gateForStudent returns that student's events newest first.
func (s *Server) gateForStudent(c *gin.Context) {
	st, ok := s.store.StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	events := s.store.GateForStudent(st.ID)
	if events == nil {
		events = []domain.GateEvent{}
	}
	sendJSON(c, events)
}
