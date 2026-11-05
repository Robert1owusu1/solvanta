package httpapi

import (
	"net/http"
	"strings"
	"testing"
)

// TestCoverAssignmentLeaderWritesStaffReads pins the scope of the cover kind:
// a school leader may assign cover, every signed-in staff member can see it
// (the substitute needs to), and a teacher cannot assign it.
func TestCoverAssignmentLeaderWritesStaffReads(t *testing.T) {
	r := newTestServer(t, Config{})
	head := login(t, r, demoAccounts["headteacher"][0], demoAccounts["headteacher"][1])
	teacher := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])

	const id = "COV-001"
	body := `{"id":"` + id + `","date":"2026-09-21","weekday":"Monday",` +
		`"lessonId":"LSN-1","classId":"JHS2A","subjectId":"MATH",` +
		`"start":"08:00","end":"09:00","absentTeacherId":"T-EFUA",` +
		`"absentTeacherName":"Ms. Efua Mensah","substituteTeacherId":"T-KOFI",` +
		`"substituteTeacherName":"Mr. Kofi","reason":"Sick leave","status":"assigned"}`

	// Leader may assign.
	rec := do(r, "PUT", "/api/records/cover_assignments/"+id, body, bearer(head))
	if rec.Code != http.StatusOK {
		t.Fatalf("leader assign cover: got %d %s", rec.Code, rec.Body.String())
	}

	// A teacher must not be able to assign cover.
	body2 := strings.Replace(body, `"id":"`+id+`"`, `"id":"COV-002"`, 1)
	rec = do(r, "PUT", "/api/records/cover_assignments/COV-002", body2, bearer(teacher))
	if rec.Code != http.StatusForbidden {
		t.Errorf("teacher assigning cover: got %d, want 403", rec.Code)
	}

	// A teacher (the substitute, among others) can read it.
	rec = do(r, "GET", "/api/records/cover_assignments", "", bearer(teacher))
	if rec.Code != http.StatusOK {
		t.Fatalf("teacher list cover: got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), id) {
		t.Error("assigned cover missing from the staff-visible list")
	}
}
