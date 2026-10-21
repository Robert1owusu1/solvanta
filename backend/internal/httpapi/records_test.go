package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRecordsSeededAndScoped(t *testing.T) {
	r := newTestServer(t, Config{})
	student := authFor(t, r, "student")
	if ids := listIDs(t, do(r, "GET", "/api/records/lessons", "", student).Body.Bytes()); len(ids) != 25 {
		t.Errorf("seeded timetable slots = %d, want 25", len(ids))
	}
	if ids := listIDs(t, do(r, "GET", "/api/records/resources", "", student).Body.Bytes()); len(ids) != 5 {
		t.Errorf("JHS2A pupil sees %d resources, want 5", len(ids))
	}
	if rec := do(r, "GET", "/api/records/nope", "", student); rec.Code != http.StatusNotFound {
		t.Errorf("unknown kind: %d", rec.Code)
	}

	// pupils cannot edit the timetable; staff can
	slot := `{"id":"SLOT-X","classId":"JHS2A","weekday":"Monday","start":"15:00","end":"15:40","subjectId":"ICT","teacherId":"USR-TCH-001"}`
	if rec := do(r, "PUT", "/api/records/lessons/SLOT-X", slot, student); rec.Code != http.StatusForbidden {
		t.Errorf("pupil timetable write: %d", rec.Code)
	}
	teacher := authFor(t, r, "teacher")
	if rec := do(r, "PUT", "/api/records/lessons/SLOT-X", slot, teacher); rec.Code != http.StatusOK {
		t.Fatalf("teacher timetable write: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "PUT", "/api/records/lessons/SLOT-Y", slot, teacher); rec.Code != http.StatusBadRequest {
		t.Errorf("mismatched id: %d", rec.Code)
	}
	if rec := do(r, "DELETE", "/api/records/lessons/SLOT-X", "", teacher); rec.Code != http.StatusOK {
		t.Errorf("delete: %d", rec.Code)
	}
	if rec := do(r, "DELETE", "/api/records/lessons/SLOT-X", "", teacher); rec.Code != http.StatusOK {
		t.Errorf("repeat delete should be a no-op: %d", rec.Code)
	}
}

func TestStudentRecordsStayWithTheirStudent(t *testing.T) {
	r := newTestServer(t, Config{})
	student := authFor(t, r, "student") // STU-001
	mine := `{"packId":"SAFE-001","studentId":"STU-001","completedOn":"2026-10-01","score":3,"total":3}`
	if rec := do(r, "PUT", "/api/records/safety_completions/SAFE-001_STU-001", mine, student); rec.Code != http.StatusOK {
		t.Fatalf("own completion: %d %s", rec.Code, rec.Body.String())
	}
	other := `{"packId":"SAFE-001","studentId":"STU-002","completedOn":"2026-10-01","score":3,"total":3}`
	if rec := do(r, "PUT", "/api/records/safety_completions/SAFE-001_STU-002", other, student); rec.Code != http.StatusForbidden {
		t.Errorf("classmate's completion: %d", rec.Code)
	}
	// the parent of STU-001 sees it; another family does not
	if got := studentIDsIn(t, do(r, "GET", "/api/records/safety_completions", "", authFor(t, r, "parent")).Body.Bytes()); !got["STU-001"] {
		t.Errorf("parent should see their child's training, got %v", got)
	}
	tok := login(t, r, "akua.boaduwaa@school.gh", "parent123")
	if got := listIDs(t, do(r, "GET", "/api/records/safety_completions", "",
		map[string]string{"Authorization": "Bearer " + tok}).Body.Bytes()); len(got) != 0 {
		t.Errorf("another family saw %v", got)
	}
}

func TestTargetsBelongToTheirOwner(t *testing.T) {
	r := newTestServer(t, Config{})
	student := authFor(t, r, "student")
	if rec := do(r, "PUT", "/api/records/targets/USR-STU-001", `{"id":"USR-STU-001","targets":{"MATH":"A"}}`, student); rec.Code != http.StatusOK {
		t.Fatalf("own targets: %d %s", rec.Code, rec.Body.String())
	}
	if got := do(r, "GET", "/api/records/targets", "", student).Body.String(); !strings.Contains(got, `"MATH":"A"`) {
		t.Errorf("owner reads back %s", got)
	}
	if got := listIDs(t, do(r, "GET", "/api/records/targets", "", authFor(t, r, "teacher")).Body.Bytes()); len(got) != 0 {
		t.Errorf("someone else saw targets %v", got)
	}
	// overwriting another user's row is refused
	if rec := do(r, "PUT", "/api/records/targets/USR-STU-001", `{"targets":{}}`, authFor(t, r, "teacher")); rec.Code != http.StatusForbidden {
		t.Errorf("foreign overwrite: %d", rec.Code)
	}
}

func TestScanImageRoundTrip(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := authFor(t, r, "teacher")
	scan := `{"id":"SCAN-1","assessmentId":"ASSMT-MATH-T1","studentId":"STU-001","imagePath":"","pageNumber":1,"capturedAt":"2026-10-01","recorder":"Ms. Efua Mensah","status":"queued"}`
	if rec := do(r, "PUT", "/api/records/scans/SCAN-1", scan, teacher); rec.Code != http.StatusOK {
		t.Fatalf("scan record: %d %s", rec.Code, rec.Body.String())
	}
	img := bytes.Repeat([]byte{0xFF, 0xD8, 0x01}, 600_000) // ~1.8 MB, over the JSON cap
	req := httptest.NewRequest("PUT", "/api/scans/SCAN-1/image", bytes.NewReader(img))
	req.Header.Set("Content-Type", "image/jpeg")
	req.Header.Set("Authorization", teacher["Authorization"])
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("upload: %d %s", rec.Code, rec.Body.String())
	}
	got := do(r, "GET", "/api/scans/SCAN-1/image", "", teacher)
	if got.Code != http.StatusOK || !bytes.Equal(got.Body.Bytes(), img) || got.Header().Get("Content-Type") != "image/jpeg" {
		t.Errorf("download: %d, %d bytes, %q", got.Code, got.Body.Len(), got.Header().Get("Content-Type"))
	}
	if rec := do(r, "GET", "/api/scans/SCAN-1/image", "", authFor(t, r, "student")); rec.Code != http.StatusOK {
		t.Errorf("pupil viewing their own scan: %d", rec.Code)
	}
	tok := login(t, r, "akua.boaduwaa@school.gh", "parent123")
	if rec := do(r, "GET", "/api/scans/SCAN-1/image", "", map[string]string{"Authorization": "Bearer " + tok}); rec.Code != http.StatusNotFound {
		t.Errorf("another family viewing the scan: %d", rec.Code)
	}
}

func TestStudentScopedNotificationsAreReadPerReader(t *testing.T) {
	r := newTestServer(t, Config{})
	admin := authFor(t, r, "schoolAdmin")
	// a second guardian for STU-001
	if rec := do(r, "POST", "/api/users", `{"name":"Kwesi Owusu","email":"kwesi.owusu@school.gh","password":"Guardian2026","role":"parent","studentIds":["STU-001"]}`, admin); rec.Code != http.StatusCreated {
		t.Fatalf("create guardian: %d %s", rec.Code, rec.Body.String())
	}
	mum := authFor(t, r, "parent")
	dad := map[string]string{"Authorization": "Bearer " + login(t, r, "kwesi.owusu@school.gh", "Guardian2026")}
	unread := func(h map[string]string) map[string]bool {
		out := map[string]bool{}
		for _, id := range listIDs(t, do(r, "GET", "/api/notifications/unread", "", h).Body.Bytes()) {
			out[id] = true
		}
		return out
	}
	if !unread(dad)["NOTIF-001"] {
		t.Fatal("the student-scoped seed notice should reach the second guardian")
	}
	if rec := do(r, "POST", "/api/notifications/NOTIF-001/read", "", mum); rec.Code != http.StatusOK {
		t.Fatalf("mark read: %d", rec.Code)
	}
	if unread(mum)["NOTIF-001"] {
		t.Error("still unread for the reader")
	}
	if !unread(dad)["NOTIF-001"] {
		t.Error("one guardian reading it cleared it for the other")
	}
}

func TestMessageReceipts(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := authFor(t, r, "teacher")
	sent := do(r, "POST", "/api/messages", `{"toId":"USR-PRN-001","subject":"Hi","body":"Hello"}`, teacher)
	var m struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(sent.Body.Bytes(), &m); err != nil || m.ID == "" {
		t.Fatalf("send: %d %s", sent.Code, sent.Body.String())
	}
	state := func() string {
		var list []struct {
			ID, State, ReadAt string
		}
		_ = json.Unmarshal(do(r, "GET", "/api/messages", "", teacher).Body.Bytes(), &list)
		for _, x := range list {
			if x.ID == m.ID {
				return x.State
			}
		}
		return ""
	}
	if s := state(); s != "sent" {
		t.Errorf("fresh message state %q", s)
	}
	if rec := do(r, "POST", "/api/messages/"+m.ID+"/receipt", `{"state":"read"}`, teacher); rec.Code != http.StatusForbidden {
		t.Errorf("sender acknowledging own message: %d", rec.Code)
	}
	parent := authFor(t, r, "parent")
	do(r, "POST", "/api/messages/"+m.ID+"/receipt", `{"state":"delivered"}`, parent)
	if s := state(); s != "delivered" {
		t.Errorf("after delivery: %q", s)
	}
	do(r, "POST", "/api/messages/"+m.ID+"/receipt", `{"state":"read"}`, parent)
	if s := state(); s != "read" {
		t.Errorf("after reading: %q", s)
	}
}

func TestUncompleteAssignment(t *testing.T) {
	r := newTestServer(t, Config{})
	student := authFor(t, r, "student")
	list := listIDs(t, do(r, "GET", "/api/assignments", "", student).Body.Bytes())
	if len(list) == 0 {
		t.Fatal("no assignments for the pupil")
	}
	id := list[0]
	do(r, "POST", "/api/assignments/"+id+"/complete", "", student)
	rec := do(r, "DELETE", "/api/assignments/"+id+"/complete", "", student)
	if rec.Code != http.StatusOK || strings.Contains(rec.Body.String(), `"STU-001"`) {
		t.Errorf("un-complete: %d %s", rec.Code, rec.Body.String())
	}
}

func TestAdminPasswordReset(t *testing.T) {
	r := newTestServer(t, Config{})
	if rec := do(r, "POST", "/api/users/USR-PRN-001/reset-password", `{"new":"Reset2026x"}`, authFor(t, r, "teacher")); rec.Code != http.StatusForbidden {
		t.Errorf("teacher reset: %d", rec.Code)
	}
	admin := authFor(t, r, "schoolAdmin")
	if rec := do(r, "POST", "/api/users/USR-PRN-001/reset-password", `{"new":"short"}`, admin); rec.Code != http.StatusBadRequest {
		t.Errorf("weak password accepted: %d", rec.Code)
	}
	if rec := do(r, "POST", "/api/users/USR-PRN-001/reset-password", `{"new":"Reset2026x"}`, admin); rec.Code != http.StatusOK {
		t.Fatalf("reset: %d %s", rec.Code, rec.Body.String())
	}
	login(t, r, "ama.owusu@school.gh", "Reset2026x")
	if rec := do(r, "POST", "/auth/login", `{"email":"ama.owusu@school.gh","password":"parent123"}`, nil); rec.Code == http.StatusOK {
		t.Error("the old password still works")
	}
	if rec := do(r, "POST", "/api/users/USR-SUPER/reset-password", `{"new":"Reset2026x"}`, admin); rec.Code != http.StatusForbidden {
		t.Errorf("school admin reset the super admin: %d", rec.Code)
	}
}
