package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

// Tests for the routes the client's server sync relies on: scoped full
// collection reads and the update/delete writes.

func authFor(t *testing.T, r http.Handler, role string) map[string]string {
	t.Helper()
	tok := login(t, r, demoAccounts[role][0], demoAccounts[role][1])
	return map[string]string{"Authorization": "Bearer " + tok}
}

// studentIDsIn decodes a list of records and returns the distinct studentIds.
func studentIDsIn(t *testing.T, body []byte) map[string]bool {
	t.Helper()
	var list []struct {
		StudentID string `json:"studentId"`
	}
	if err := json.Unmarshal(body, &list); err != nil {
		t.Fatalf("decode list: %v (%s)", err, body)
	}
	ids := map[string]bool{}
	for _, x := range list {
		ids[x.StudentID] = true
	}
	return ids
}

func TestAttendanceAndSubmissionListsAreScoped(t *testing.T) {
	r := newTestServer(t, Config{})
	for _, path := range []string{"/api/attendance", "/api/submissions"} {
		admin := do(r, "GET", path, "", authFor(t, r, "schoolAdmin"))
		if admin.Code != http.StatusOK {
			t.Fatalf("admin %s: %d %s", path, admin.Code, admin.Body.String())
		}
		if len(studentIDsIn(t, admin.Body.Bytes())) < 2 {
			t.Errorf("admin %s should span several students", path)
		}
		for _, role := range []string{"parent", "student"} {
			rec := do(r, "GET", path, "", authFor(t, r, role))
			if rec.Code != http.StatusOK {
				t.Fatalf("%s %s: %d", role, path, rec.Code)
			}
			for id := range studentIDsIn(t, rec.Body.Bytes()) {
				if id != "STU-001" {
					t.Errorf("%s %s leaked records for %s", role, path, id)
				}
			}
		}
	}
	if n := len(studentIDsIn(t, do(r, "GET", "/api/attendance", "", authFor(t, r, "student")).Body.Bytes())); n != 1 {
		t.Errorf("student should see their own attendance, saw %d students", n)
	}
}

func TestListNotificationsIncludesReadOnes(t *testing.T) {
	r := newTestServer(t, Config{})
	auth := authFor(t, r, "parent")
	all := listIDs(t, do(r, "GET", "/api/notifications", "", auth).Body.Bytes())
	if len(all) == 0 {
		t.Fatal("parent should have notifications")
	}
	if rec := do(r, "POST", "/api/notifications/read-all", "", auth); rec.Code != http.StatusOK {
		t.Fatalf("read-all: %d", rec.Code)
	}
	if unread := listIDs(t, do(r, "GET", "/api/notifications/unread", "", auth).Body.Bytes()); len(unread) != 0 {
		t.Errorf("unread after read-all = %v", unread)
	}
	if after := listIDs(t, do(r, "GET", "/api/notifications", "", auth).Body.Bytes()); len(after) != len(all) {
		t.Errorf("full list shrank after read-all: %d -> %d", len(all), len(after))
	}
}

func TestUpdateUserLinksChildrenAndGuardsRoles(t *testing.T) {
	r := newTestServer(t, Config{})
	admin := authFor(t, r, "schoolAdmin")

	rec := do(r, "PATCH", "/api/users/USR-PRN-001", `{"studentIds":["STU-001","STU-002"],"phone":"0200000001"}`, admin)
	if rec.Code != http.StatusOK {
		t.Fatalf("link children: %d %s", rec.Code, rec.Body.String())
	}
	var u struct {
		Phone      string   `json:"phone"`
		StudentIDs []string `json:"studentIds"`
		Password   string   `json:"password"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &u)
	if len(u.StudentIDs) != 2 || u.Phone != "0200000001" || u.Password != "" {
		t.Errorf("unexpected user after update: %+v", u)
	}
	// The parent still signs in with the old password.
	login(t, r, "ama.owusu@school.gh", "parent123")

	if rec := do(r, "PATCH", "/api/users/USR-PRN-001", `{"studentIds":["STU-404"]}`, admin); rec.Code != http.StatusBadRequest {
		t.Errorf("unknown student link: got %d, want 400", rec.Code)
	}
	if rec := do(r, "PATCH", "/api/users/USR-TCH-001", `{"role":"superAdmin"}`, admin); rec.Code != http.StatusForbidden {
		t.Errorf("school admin granting super admin: got %d, want 403", rec.Code)
	}
	if rec := do(r, "PATCH", "/api/users/USR-PRN-001", `{"phone":"1"}`, authFor(t, r, "teacher")); rec.Code != http.StatusForbidden {
		t.Errorf("teacher editing a user: got %d, want 403", rec.Code)
	}
}

func TestStudentPatchSetsStatusAndParent(t *testing.T) {
	r := newTestServer(t, Config{})
	admin := authFor(t, r, "schoolAdmin")
	rec := do(r, "PATCH", "/api/students/STU-002", `{"status":"Transferred","admissionNo":"S-9","parentUserId":""}`, admin)
	if rec.Code != http.StatusOK {
		t.Fatalf("patch: %d %s", rec.Code, rec.Body.String())
	}
	var st struct {
		Status       string `json:"status"`
		AdmissionNo  string `json:"admissionNo"`
		ParentUserID string `json:"parentUserId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &st)
	if st.Status != "Transferred" || st.AdmissionNo != "S-9" || st.ParentUserID != "" {
		t.Errorf("unexpected student after patch: %+v", st)
	}
	if rec := do(r, "PATCH", "/api/students/STU-002", `{"parentUserId":"USR-TCH-001"}`, admin); rec.Code != http.StatusBadRequest {
		t.Errorf("linking a non-parent: got %d, want 400", rec.Code)
	}
}

func TestSaveClassAndUpdateAssessment(t *testing.T) {
	r := newTestServer(t, Config{})
	admin := authFor(t, r, "schoolAdmin")
	if rec := do(r, "PUT", "/api/school/classes/JHS1C", `{"name":"JHS 1","stream":"C"}`, admin); rec.Code != http.StatusOK {
		t.Fatalf("save class: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(r, "PUT", "/api/school/classes/JHS1C", `{"name":"JHS 1","stream":"C"}`, authFor(t, r, "teacher")); rec.Code != http.StatusForbidden {
		t.Errorf("teacher saving a class: got %d, want 403", rec.Code)
	}

	list := do(r, "GET", "/api/assessments", "", admin)
	var as []map[string]any
	_ = json.Unmarshal(list.Body.Bytes(), &as)
	if len(as) == 0 {
		t.Fatal("no seeded assessments")
	}
	a := as[0]
	a["title"] = "Renamed paper"
	body, _ := json.Marshal(a)
	rec := do(r, "PUT", "/api/assessments/"+a["id"].(string), string(body), admin)
	if rec.Code != http.StatusOK {
		t.Fatalf("update assessment: %d %s", rec.Code, rec.Body.String())
	}
	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["title"] != "Renamed paper" || got["id"] != a["id"] {
		t.Errorf("update did not keep id / apply title: %v", got)
	}
}

func TestDeleteAnnouncementAndAssignment(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := authFor(t, r, "teacher")
	admin := authFor(t, r, "schoolAdmin")

	created := do(r, "POST", "/api/announcements", `{"title":"Sports day","body":"Friday","audience":"school"}`, admin)
	var ann struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(created.Body.Bytes(), &ann)
	if rec := do(r, "DELETE", "/api/announcements/"+ann.ID, "", teacher); rec.Code != http.StatusForbidden {
		t.Errorf("teacher deleting admin's announcement: got %d, want 403", rec.Code)
	}
	if rec := do(r, "DELETE", "/api/announcements/"+ann.ID, "", admin); rec.Code != http.StatusOK {
		t.Fatalf("delete announcement: %d", rec.Code)
	}
	for _, id := range listIDs(t, do(r, "GET", "/api/announcements", "", admin).Body.Bytes()) {
		if id == ann.ID {
			t.Error("deleted announcement still listed")
		}
	}

	created = do(r, "POST", "/api/assignments", `{"classId":"JHS2A","subjectId":"MATH","title":"Ex 4","deadline":"2026-12-01"}`, teacher)
	var asg struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(created.Body.Bytes(), &asg)
	if rec := do(r, "DELETE", "/api/assignments/"+asg.ID, "", authFor(t, r, "student")); rec.Code != http.StatusForbidden {
		t.Errorf("student deleting an assignment: got %d, want 403", rec.Code)
	}
	if rec := do(r, "DELETE", "/api/assignments/"+asg.ID, "", teacher); rec.Code != http.StatusOK {
		t.Fatalf("delete assignment: %d", rec.Code)
	}
}
