package httpapi

import (
	"net/http"
	"testing"
)

func meeting(status, when string) string {
	return `{"id":"MEET-1","studentId":"STU-001","classId":"JHS2A","year":"2026/2027","term":"Term 1",` +
		`"reason":"Year average below 45","status":"` + status + `","scheduledFor":"` + when + `","place":"Staff room"}`
}

func TestParentMeetings(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	parent := login(t, r, "ama.owusu@school.gh", "parent123")
	other := login(t, r, "nana.darko@school.gh", "parent123") // STU-005's parent
	const path = "/api/records/parent_meetings/MEET-1"

	if rec := do(r, "PUT", path, meeting("requested", ""), bearer(teacher)); rec.Code != http.StatusOK {
		t.Fatalf("request: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "PUT", path, meeting("scheduled", ""), bearer(teacher)); rec.Code != http.StatusBadRequest {
		t.Errorf("booking without a time: got %d, want 400", rec.Code)
	}
	if rec := do(r, "PUT", path, meeting("bogus", ""), bearer(teacher)); rec.Code != http.StatusBadRequest {
		t.Errorf("unknown status: got %d, want 400", rec.Code)
	}
	if rec := do(r, "PUT", path, meeting("scheduled", "2026-12-04 10:00"), bearer(teacher)); rec.Code != http.StatusOK {
		t.Fatalf("book: %d", rec.Code)
	}
	if rec := do(r, "PUT", path, meeting("cancelled", ""), bearer(parent)); rec.Code != http.StatusForbidden {
		t.Errorf("parent writing a meeting: got %d, want 403", rec.Code)
	}

	var rows []map[string]any
	getJSON(t, r, parent, "/api/records/parent_meetings", &rows)
	if len(rows) != 1 || rows[0]["scheduledFor"] != "2026-12-04 10:00" {
		t.Fatalf("parent's meetings: %v", rows)
	}
	getJSON(t, r, other, "/api/records/parent_meetings", &rows)
	if len(rows) != 0 {
		t.Fatalf("another family sees the meeting: %v", rows)
	}
	var notes []map[string]any
	getJSON(t, r, parent, "/api/notifications", &notes)
	found := false
	for _, n := range notes {
		found = found || n["kind"] == "meeting"
	}
	if !found {
		t.Fatalf("no meeting notice for the parent: %v", notes)
	}
}
