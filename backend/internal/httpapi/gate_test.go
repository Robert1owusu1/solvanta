package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

const replayID = "GATE-1759372800000"

// TestGateEventReplayIsIdempotent covers the offline gate device: it records
// the arrival locally first and pushes afterwards, so the push may be retried
// (a lost response, an expired session) after the server already stored it.
// The client merges the local and server trails by id, so a server-assigned
// id would show one arrival as two — in a safety log, on the pickup screen.
func TestGateEventReplayIsIdempotent(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}

	body := `{"id":"` + replayID + `","studentId":"STU-001","type":"arrival",` +
		`"time":"07:45","date":"2026-09-30","reporter":"Ms. Efua Mensah",` +
		`"detail":"Arrival verified at gate"}`

	ids := make([]string, 0, 2)
	for attempt := 0; attempt < 2; attempt++ {
		rec := do(r, http.MethodPost, "/api/gate/events", body, hdr)
		if rec.Code != http.StatusCreated {
			t.Fatalf("attempt %d: got %d %s", attempt, rec.Code, rec.Body.String())
		}
		var created struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
			t.Fatalf("attempt %d: decode: %v", attempt, err)
		}
		ids = append(ids, created.ID)
	}

	if ids[0] != replayID {
		t.Fatalf("server replaced the client id with %q — the device's local copy would never match it again", ids[0])
	}
	if ids[1] != ids[0] {
		t.Fatalf("replayed push returned a different id: %q then %q", ids[0], ids[1])
	}

	list := do(r, http.MethodGet, "/api/gate/events", "", hdr)
	if list.Code != http.StatusOK {
		t.Fatalf("list: got %d", list.Code)
	}
	var events []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &events); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	copies := 0
	for _, e := range events {
		if e.ID == replayID {
			copies++
		}
	}
	if copies != 1 {
		t.Fatalf("one arrival recorded as %d events in the trail", copies)
	}
}

// TestCreateGateEventGeneratesIDWhenAbsent keeps the plain server-side path
// working for clients that do not supply an id.
func TestCreateGateEventGeneratesIDWhenAbsent(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}

	rec := do(r, http.MethodPost, "/api/gate/events",
		`{"studentId":"STU-001","type":"departure","time":"15:30","date":"2026-09-30"}`, hdr)
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d %s", rec.Code, rec.Body.String())
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if created.ID == "" {
		t.Fatal("no id assigned when the client sends none")
	}
	if created.ID == replayID {
		t.Fatal("reused a client id that was never sent")
	}
}
