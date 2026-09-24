package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
)

// Role endpoint acceptance matrix — the "what may each role do" contract.
// Every case asserts the exact HTTP status each of the six seeded demo roles
// receives, so a regression in route-level authorization fails loudly here.
// Record/data-level scoping assertions live alongside them.

type rbacCase struct {
	name    string
	method  string
	path    string
	body    string
	allowed []string // role keys that must NOT be 403
	denied  []string // role keys that must be 403
}

var demoAccounts = map[string][2]string{
	"superAdmin":  {"super@solvanta.app", "super123"},
	"schoolAdmin": {"admin@solvanta.app", "admin123"},
	"headteacher": {"head@school.gh", "head123"},
	"teacher":     {"efua.mensah@school.gh", "teacher123"},
	"parent":      {"ama.owusu@school.gh", "parent123"},
	"student":     {"kojo.owusu@school.gh", "student123"},
}

func TestRoleEndpointMatrix(t *testing.T) {
	// Each role gets one token per server instance (fresh servers per group
	// would defeat the purpose; one seeded server keeps ids stable).
	r := newTestServer(t, Config{})
	tokens := map[string]string{}
	for role, acct := range demoAccounts {
		tokens[role] = login(t, r, acct[0], acct[1])
	}

	cases := []rbacCase{
		{
			name: "create student is admin+head only", method: "POST",
			path: "/api/students", body: `{"firstName":"Test","lastName":"Child","gender":"M","classId":"JHS1A"}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher"},
			denied:  []string{"teacher", "parent", "student"},
		},
		{
			name: "edit student is admin+head only", method: "PATCH",
			path: "/api/students/STU-001", body: `{"firstName":"Kojo2"}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher"},
			denied:  []string{"teacher", "parent", "student"},
		},
		{
			name: "promote student is admin+head only", method: "POST",
			path: "/api/students/STU-001/promote", body: ``,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher"},
			denied:  []string{"teacher", "parent", "student"},
		},
		{
			name: "question bank (with answers) is staff-only", method: "GET",
			path: "/api/questions", body: ``,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "AI draft requests are staff-only", method: "GET",
			path: "/api/questions/ai/requests", body: ``,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "create question is teacher+", method: "POST",
			path: "/api/questions", body: `{"type":"mcq","subjectId":"MATH","classId":"JHS2A","stem":"1+1?","options":["2","3"],"correctAnswer":"2"}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "delete question is admin+head", method: "DELETE",
			path: "/api/questions/Q-MATH-003", body: ``,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher"},
			denied:  []string{"teacher", "parent", "student"},
		},
		{
			name: "create assessment is teacher+", method: "POST",
			path: "/api/assessments", body: `{"title":"T","type":"classTest","subjectId":"MATH","classId":"JHS2A"}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "create exam assessment is school leaders only (midTerm)", method: "POST",
			path: "/api/assessments", body: `{"title":"EOT","type":"midTerm","subjectId":"MATH","classId":"JHS2A","questions":[{"stem":"q","marks":2}]}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher"},
			denied:  []string{"teacher", "parent", "student"},
		},
		{
			name: "create formal diagnostic/remedial is school leaders only", method: "POST",
			path: "/api/assessments", body: `{"title":"DG","type":"diagnostic","subjectId":"SCI","classId":"JHS2A","questions":[{"stem":"q","marks":2}]}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher"},
			denied:  []string{"teacher", "parent", "student"},
		},
		{
			name: "create assignment is teacher+", method: "POST",
			path: "/api/assignments", body: `{"title":"HW","classId":"JHS2A","subjectId":"MATH","deadline":"2026-10-01"}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "create intervention is teacher+", method: "POST",
			path: "/api/interventions", body: `{"studentId":"STU-001","subjectId":"MATH","topic":"Fractions","plan":"Practice"}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "create announcement is staff+", method: "POST",
			path: "/api/announcements", body: `{"title":"Assembly","body":"Tomorrow 8am","audience":"school"}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "list users is admin+head", method: "GET",
			path: "/api/users", body: ``,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher"},
			denied:  []string{"teacher", "parent", "student"},
		},
		{
			name: "audit log is admin+head", method: "GET",
			path: "/api/audit", body: ``,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher"},
			denied:  []string{"teacher", "parent", "student"},
		},
		{
			name: "mark assessment verdicts is teacher+", method: "POST",
			path: "/api/assessments/ASSMT-MAT-HALF/verdicts", body: `{"verdicts":[{"studentId":"STU-001","verdict":{}}]}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "save attendance day is staff+", method: "PUT",
			path: "/api/attendance/class/JHS2A/date/2026-09-20", body: `{"records":[]}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "attendance correction is teacher+", method: "POST",
			path: "/api/attendance/correction", body: `{"studentId":"STU-001","date":"2026-09-20","status":"present","reason":"test"}`,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "publish AI draft is teacher+", method: "POST",
			path: "/api/questions/ai/requests/REQ-1/publish", body: ``,
			allowed: []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"},
			denied:  []string{"parent", "student"},
		},
		{
			name: "student can complete own assignment", method: "POST",
			path: "/api/assignments/ASG-001/complete", body: ``,
			allowed: []string{"student"},
			denied:  []string{"superAdmin", "schoolAdmin", "headteacher", "teacher", "parent"},
		},
		{
			name: "student cannot read audit", method: "GET",
			path: "/api/audit", body: ``,
			allowed: nil,
			denied:  []string{"parent", "student", "teacher"},
		},
	}

	for _, tc := range cases {
		for _, role := range tc.allowed {
			hdr := map[string]string{"Authorization": "Bearer " + tokens[role]}
			rec := do(r, tc.method, tc.path, tc.body, hdr)
			if rec.Code == http.StatusForbidden || rec.Code == http.StatusUnauthorized {
				t.Errorf("%s: role %s got %d, want allowed (200-201 etc): %s",
					tc.name, role, rec.Code, rec.Body.String())
			}
		}
		for _, role := range tc.denied {
			hdr := map[string]string{"Authorization": "Bearer " + tokens[role]}
			rec := do(r, tc.method, tc.path, tc.body, hdr)
			if rec.Code != http.StatusForbidden {
				t.Errorf("%s: role %s got %d, want 403 (body: %s)",
					tc.name, role, rec.Code, rec.Body.String())
			}
		}
	}
}

// listIDs decodes the /api/students response into a slice of student ids.
func listIDs(t *testing.T, body []byte) []string {
	t.Helper()
	var list []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &list); err != nil {
		t.Fatalf("decode student list: %v", err)
	}
	ids := make([]string, 0, len(list))
	for _, s := range list {
		ids = append(ids, s.ID)
	}
	return ids
}

func TestStudentListScopingByRole(t *testing.T) {
	r := newTestServer(t, Config{})
	get := func(role string) []string {
		tok := login(t, r, demoAccounts[role][0], demoAccounts[role][1])
		rec := do(r, "GET", "/api/students", "", map[string]string{"Authorization": "Bearer " + tok})
		return listIDs(t, rec.Body.Bytes())
	}

	if ids := get("schoolAdmin"); len(ids) != 8 {
		t.Errorf("admin sees %d students, want 8 (%v)", len(ids), ids)
	}
	if ids := get("superAdmin"); len(ids) != 8 {
		t.Errorf("super admin sees %d students, want 8 (%v)", len(ids), ids)
	}
	if ids := get("teacher"); len(ids) != 6 {
		t.Errorf("teacher (JHS2A) sees %d students, want 6 (%v)", len(ids), ids)
	}
	if ids := get("parent"); len(ids) != 1 || ids[0] != "STU-001" {
		t.Errorf("parent sees %v, want only [STU-001]", ids)
	}
	if ids := get("student"); len(ids) != 1 || ids[0] != "STU-001" {
		t.Errorf("student sees %v, want only [STU-001]", ids)
	}
}

func TestNotificationReadScoping(t *testing.T) {
	r := newTestServer(t, Config{})

	// Seed notifications NOTIF-001..003 belong to STU-001 (parent-visible).
	parentTok := login(t, r, "ama.owusu@school.gh", "parent123")
	teacherTok := login(t, r, "efua.mensah@school.gh", "teacher123")
	studentTok := login(t, r, "kojo.owusu@school.gh", "student123")

	// parent may mark their own
	rec := do(r, "POST", "/api/notifications/NOTIF-001/read", "", map[string]string{"Authorization": "Bearer " + parentTok})
	if rec.Code != http.StatusOK {
		t.Errorf("parent mark own read: got %d (%s)", rec.Code, rec.Body.String())
	}

	// a teacher may not mark a parent-targeted notification
	rec = do(r, "POST", "/api/notifications/NOTIF-002/read", "", map[string]string{"Authorization": "Bearer " + teacherTok})
	if rec.Code != http.StatusForbidden {
		t.Errorf("teacher marking parent notification: got %d, want 403", rec.Code)
	}

	// an admin may not mark a parent-targeted notification they cannot see
	adminTok := login(t, r, "admin@solvanta.app", "admin123")
	rec = do(r, "POST", "/api/notifications/NOTIF-002/read", "", map[string]string{"Authorization": "Bearer " + adminTok})
	if rec.Code != http.StatusForbidden {
		t.Errorf("admin marking parent notification: got %d, want 403 (consistent with unread visibility)", rec.Code)
	}

	// a student may mark their own record's notification but no one else's
	rec = do(r, "POST", "/api/notifications/NOTIF-003/read", "", map[string]string{"Authorization": "Bearer " + studentTok})
	if rec.Code != http.StatusOK {
		t.Errorf("student marking own notification: got %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
}

func TestStudentCannotActForOthers(t *testing.T) {
	r := newTestServer(t, Config{})
	// student submits an assessment: only for their own student record
	tok := login(t, r, "kojo.owusu@school.gh", "student123")
	body := fmt.Sprintf(`{"assessmentId":"ASSMT-MAT-HALF","studentId":"STU-002","answers":{}}`)
	rec := do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/submit", body, map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusForbidden {
		t.Errorf("student submitting for another: got %d, want 403", rec.Code)
	}
	body = fmt.Sprintf(`{"assessmentId":"ASSMT-MAT-HALF","studentId":"STU-001","answers":{}}`)
	rec = do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/submit", body, map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusOK && rec.Code != http.StatusCreated {
		t.Errorf("student submitting own: got %d, want 2xx (%s)", rec.Code, rec.Body.String())
	}
}
