package httpapi

import (
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// failingStore wraps a healthy store and makes exactly one payload write fail,
// the way a dropped Supabase connection does at runtime. Every other method is
// promoted from the embedded interface, so the failure is isolated to the
// write under test.
type failingStore struct {
	store.Store
	failOn string
}

func (f *failingStore) failure(method string) error {
	if f.failOn == method {
		return errors.New("pq: server closed the connection unexpectedly")
	}
	return nil
}

func (f *failingStore) AddGateEvent(e domain.GateEvent) error {
	if err := f.failure("AddGateEvent"); err != nil {
		return err
	}
	return f.Store.AddGateEvent(e)
}

func (f *failingStore) SaveStudent(s domain.Student) error {
	if err := f.failure("SaveStudent"); err != nil {
		return err
	}
	return f.Store.SaveStudent(s)
}

func (f *failingStore) SavePayment(p domain.Payment) error {
	if err := f.failure("SavePayment"); err != nil {
		return err
	}
	return f.Store.SavePayment(p)
}

func (f *failingStore) SaveInvoice(inv domain.Invoice) error {
	if err := f.failure("SaveInvoice"); err != nil {
		return err
	}
	return f.Store.SaveInvoice(inv)
}

// newFailingServer builds the API over a store whose named write fails.
func newFailingServer(t *testing.T, failOn string) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	s, err := NewServer(&failingStore{Store: store.New(), failOn: failOn}, Config{})
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return s.Router()
}

// TestGateWriteFailureReturns500WithoutLeaking pins the contract this change
// introduced: a store write that fails must surface as 500, never as 201 for
// a row that was never stored. Every handler used to discard the store's
// error, so a gate arrival pushed against a dead connection was reported
// "created" and simply vanished from the safety log. The generic message
// also proves no SQL or driver detail reaches the client.
func TestGateWriteFailureReturns500WithoutLeaking(t *testing.T) {
	r := newFailingServer(t, "AddGateEvent")
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}

	// Control: a write this server does NOT fail still succeeds, so the 500
	// below is the injected failure and not a mis-wired fixture.
	stud := do(r, http.MethodPost, "/api/students",
		`{"firstName":"Ama","lastName":"ControlProbe","gender":"F","classId":"JHS2A"}`, hdr)
	if stud.Code != http.StatusCreated {
		t.Fatalf("control student create: got %d %s", stud.Code, stud.Body.String())
	}

	const marker = "INJECTED-FAILURE-PROBE"
	rec := do(r, http.MethodPost, "/api/gate/events",
		`{"studentId":"STU-001","type":"arrival","time":"07:45","date":"2026-09-30",`+
			`"detail":"`+marker+`"}`, hdr)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("failed write answered %d %s — the client would treat an unwritten event as saved",
			rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, `"error"`) {
		t.Fatalf("500 body is not an error payload: %s", body)
	}
	for _, leak := range []string{"pq:", "INSERT", "SELECT", "connection", "driver", "store."} {
		if strings.Contains(body, leak) {
			t.Fatalf("500 body leaks storage detail %q: %s", leak, body)
		}
	}

	// Nothing was written and the handler stopped where it should.
	list := do(r, http.MethodGet, "/api/gate/events", "", hdr)
	if list.Code != http.StatusOK {
		t.Fatalf("list: got %d %s", list.Code, list.Body.String())
	}
	if strings.Contains(list.Body.String(), marker) {
		t.Fatal("a failed write still ended up in the gate trail")
	}
}

// TestStudentWriteFailureReturns500AndStoresNothing covers a second endpoint so
// the behaviour is not specific to the gate path, and checks that the handler
// returns before it audits or notifies anyone about a row that was never saved.
func TestStudentWriteFailureReturns500AndStoresNothing(t *testing.T) {
	r := newFailingServer(t, "SaveStudent")
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}

	// Control: the store's other writes work on this same server.
	gate := do(r, http.MethodPost, "/api/gate/events",
		`{"studentId":"STU-001","type":"departure","time":"15:30","date":"2026-09-30"}`, hdr)
	if gate.Code != http.StatusCreated {
		t.Fatalf("control gate event: got %d %s", gate.Code, gate.Body.String())
	}

	const marker = "WriteFailProbe"
	rec := do(r, http.MethodPost, "/api/students",
		`{"firstName":"Kojo","lastName":"`+marker+`","gender":"M","classId":"JHS2A"}`, hdr)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("failed student create answered %d %s", rec.Code, rec.Body.String())
	}

	list := do(r, http.MethodGet, "/api/students", "", hdr)
	if list.Code != http.StatusOK {
		t.Fatalf("list: got %d %s", list.Code, list.Body.String())
	}
	if strings.Contains(list.Body.String(), marker) {
		t.Fatal("a student whose save failed is listed as if it existed")
	}
}
