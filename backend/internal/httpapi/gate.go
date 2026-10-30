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
	for _, e := range s.db(c).GateEvents() {
		if date == "" || e.Date == date {
			out = append(out, e)
		}
	}
	sendJSON(c, out)
}

// gateEventRequest carries the client's own id when it has one. The gate
// device records the event locally first and only then pushes it, so the id
// it created offline is the merge key: the server must reuse it or the same
// arrival exists twice — once under each id — once the two trails are merged
// (and again on every retried POST, since the insert is keyed on id).
type gateEventRequest struct {
	ID        string `json:"id"`
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
	st, ok := s.db(c).StudentByID(body.StudentID)
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	u := currentUser(c)
	ev := domain.GateEvent{
		// Honour a client-supplied id so a retried push is idempotent:
		// AddGateEvent inserts ON CONFLICT (id) DO NOTHING, so replaying the
		// same offline capture writes nothing the second time. Devices that
		// push straight through never send one and still get a fresh id.
		ID:        firstNonEmpty(body.ID, newID("GATE")),
		StudentID: st.ID,
		Type:      body.Type,
		Time:      firstNonEmpty(body.Time, now()[11:16]),
		Date:      firstNonEmpty(body.Date, today()),
		Reporter:  firstNonEmpty(body.Reporter, u.Name),
		Person:    body.Person,
		Detail:    body.Detail,
	}
	if writeFailed(c, s.db(c).AddGateEvent(ev)) {
		return
	}
	s.audit(c, "gate.update", ev.ID, "Gate event "+ev.Type+" for "+st.FullName(), body.Detail)

	if p := userForStudent(c, s, st); p.ID != "" {
		switch ev.Type {
		case domain.GateUnauthorizedPickup:
			s.notify(c, p.ID, domain.NotifGate, "Unverified pickup attempt for "+st.FullName(),
				"Someone not on the authorized list attempted pickup at "+ev.Time+". Please verify. Contact the school immediately.", st.ID)
		case domain.GateEarlyDeparture:
			s.notify(c, p.ID, domain.NotifGate, st.FullName()+" left school early",
				"Early departure recorded at "+ev.Time+": "+ev.Detail, st.ID)
		case domain.GateDeparture:
			s.notify(c, p.ID, domain.NotifGate, st.FullName()+" left school",
				st.FullName()+" departed at "+ev.Time+".", st.ID)
		}
	}
	sendCreated(c, ev)
}

// gateForStudent returns that student's events newest first.
func (s *Server) gateForStudent(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	events := s.db(c).GateForStudent(st.ID)
	if events == nil {
		events = []domain.GateEvent{}
	}
	sendJSON(c, events)
}
