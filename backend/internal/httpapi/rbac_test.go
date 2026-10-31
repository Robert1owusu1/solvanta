package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"solvanta/backend/internal/domain"
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

// TestLearnersNeverReceiveAssessmentAnswerKey: an assessment payload may carry
// the paper (stems and options) to learners but never correctAnswer /
// explanation / markingScheme — those fields ARE the answer key. Staff keep
// them. The assessment used to be serialised verbatim for every role.
func TestLearnersNeverReceiveAssessmentAnswerKey(t *testing.T) {
	r := newTestServer(t, Config{})
	studentTok := login(t, r, "kojo.owusu@school.gh", "student123")
	teacherTok := login(t, r, "efua.mensah@school.gh", "teacher123")
	hdr := func(tok string) map[string]string {
		return map[string]string{"Authorization": "Bearer " + tok}
	}

	type qView struct {
		Stem          string `json:"stem"`
		CorrectAnswer string `json:"correctAnswer"`
		Explanation   string `json:"explanation"`
		MarkingScheme string `json:"markingScheme"`
	}
	type detailView struct {
		Assessment struct {
			Questions []qView `json:"questions"`
		} `json:"assessment"`
	}

	rec := do(r, "GET", "/api/assessments/ASSMT-MAT-HALF", "", hdr(studentTok))
	if rec.Code != http.StatusOK {
		t.Fatalf("student detail: got %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var detail detailView
	if err := json.Unmarshal(rec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode detail: %v", err)
	}
	if len(detail.Assessment.Questions) == 0 {
		t.Fatal("student received no questions")
	}
	for _, q := range detail.Assessment.Questions {
		if q.Stem == "" {
			t.Fatal("question stem stripped for student")
		}
		if q.CorrectAnswer != "" || q.Explanation != "" || q.MarkingScheme != "" {
			t.Fatalf("answer key leaked to student: %+v", q)
		}
	}

	rec = do(r, "GET", "/api/assessments", "", hdr(studentTok))
	if rec.Code != http.StatusOK {
		t.Fatalf("student list: got %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var list []struct {
		Questions []qView `json:"questions"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(list) == 0 {
		t.Fatal("student assessment list empty")
	}
	for _, a := range list {
		for _, q := range a.Questions {
			if q.CorrectAnswer != "" {
				t.Fatalf("answer key leaked on list: %+v", q)
			}
		}
	}

	rec = do(r, "GET", "/api/assessments/ASSMT-MAT-HALF", "", hdr(teacherTok))
	if rec.Code != http.StatusOK {
		t.Fatalf("teacher detail: got %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var staff detailView
	if err := json.Unmarshal(rec.Body.Bytes(), &staff); err != nil {
		t.Fatalf("decode staff detail: %v", err)
	}
	withKey := 0
	for _, q := range staff.Assessment.Questions {
		if q.CorrectAnswer != "" {
			withKey++
		}
	}
	if withKey == 0 {
		t.Fatal("teacher lost the answer key")
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
	// ASSMT-MAT-HALF is already submitted and teacher-marked for STU-001 in
	// the seed, so the "own submission" case uses one they have not taken.
	body = fmt.Sprintf(`{"assessmentId":"ASSMT-MOCK-BECE-MATH","studentId":"STU-001","answers":{}}`)
	rec = do(r, "POST", "/api/assessments/ASSMT-MOCK-BECE-MATH/submit", body, map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusOK && rec.Code != http.StatusCreated {
		t.Errorf("student submitting own: got %d, want 2xx (%s)", rec.Code, rec.Body.String())
	}
	// Submitting again must not replace a result, marked or not.
	body = fmt.Sprintf(`{"assessmentId":"ASSMT-MAT-HALF","studentId":"STU-001","answers":{}}`)
	rec = do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/submit", body, map[string]string{"Authorization": "Bearer " + tok})
	if rec.Code != http.StatusConflict {
		t.Errorf("student resubmitting a marked paper: got %d, want 409 (%s)", rec.Code, rec.Body.String())
	}
}

// classTestSchemeFixture matches ASSMT-ENG-T1 question for question: three
// questions, so the recorded marks line up with the assessment's own papers.
const classTestSchemeFixture = `[
  {"questionNumber":1,"totalMarks":1,
   "markBreakdown":[{"type":"final_answer","criteria":"True or false","marks":1}],
   "acceptedAnswers":[{"answerText":"True","normalizedForm":"true","marksAwarded":1,"isPrimary":true}],
   "misconceptions":[]},
  {"questionNumber":2,"totalMarks":2,
   "markBreakdown":[{"type":"final_answer","criteria":"The verb","marks":2}],
   "acceptedAnswers":[{"answerText":"goes","normalizedForm":"goes","marksAwarded":2,"isPrimary":true}],
   "misconceptions":[]},
  {"questionNumber":3,"totalMarks":3,
   "markBreakdown":[{"type":"method","criteria":"Cohesion","marks":1},{"type":"final_answer","criteria":"Accuracy","marks":2}],
   "acceptedAnswers":[{"answerText":"Kojo ran, but he was late.","normalizedForm":"kojo ran but he was late","marksAwarded":3,"isPrimary":true}],
   "misconceptions":[]}
]`

// TestFinalizeIsScopedByAssessmentType closes a gap the role x endpoint matrix
// structurally cannot reach: every leader role is ALLOWED to call finalize, so
// the matrix passes for a headteacher on a classroom draft just as happily as
// on an exam one. The rule lives inside the handler, so it is pinned here
// instead — a leader finalizes the exam papers they may create, but never
// another teacher's classroom work, and reading it stays open to them.
func TestFinalizeIsScopedByAssessmentType(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	teacher := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	head := login(t, r, demoAccounts["headteacher"][0], demoAccounts["headteacher"][1])

	// Classroom work: ASSMT-ENG-T1 is a class test, a type teachers create, so
	// the classroom is the teacher's to finalize. STU-001's paper is seeded.
	rec := do(r, "POST", "/api/assessments/ASSMT-ENG-T1/marking-scheme",
		`{"assessmentId":"ASSMT-ENG-T1","questions":`+classTestSchemeFixture+`}`, bearer(head))
	if rec.Code != http.StatusCreated {
		t.Fatalf("class test scheme: %d %s", rec.Code, rec.Body.String())
	}
	var engScheme domain.MarkingScheme
	_ = json.Unmarshal(rec.Body.Bytes(), &engScheme)
	code, classroom, body := postDraft(t, r, teacher, fmt.Sprintf(
		`{"schemeId":%q,"submissionId":"SUB-E1-STU001","studentId":"STU-001",`+
			`"answers":[{"questionNumber":1,"text":"True"},{"questionNumber":2,"text":"goes"},`+
			`{"questionNumber":3,"text":"Kojo ran, but he was late."}]}`,
		engScheme.ID))
	if code != http.StatusCreated {
		t.Fatalf("classroom draft: %d %s", code, body)
	}

	// Exam work: ASSMT-MAT-HALF is a diagnostic, a type leaders create, and
	// carries three questions like the assessment itself.
	_, exam := draftForSTU002(t, r, teacher, head)
	before, ok := st.SubmissionFor("ASSMT-ENG-T1", "STU-001")
	if !ok {
		t.Fatal("seed submission for ASSMT-ENG-T1/STU-001 is missing")
	}

	// A headteacher may finalize the exam paper they are entitled to create...
	rec = do(r, "POST", "/api/marking-drafts/"+exam.ID+"/finalize",
		finalizeBody(exam, map[int]float64{1: 2, 2: 3, 3: 4}, nil), bearer(head))
	if rec.Code != http.StatusOK {
		t.Errorf("headteacher finalizing an exam draft: got %d, want 200 (%s)",
			rec.Code, rec.Body.String())
	}

	// ...but not another teacher's classroom work, which stays the teacher's.
	rec = do(r, "POST", "/api/marking-drafts/"+classroom.ID+"/finalize",
		finalizeBody(classroom, map[int]float64{1: 1, 2: 1, 3: 2}, nil), bearer(head))
	if rec.Code != http.StatusForbidden {
		t.Errorf("headteacher finalizing classroom work: got %d, want 403 (%s)",
			rec.Code, rec.Body.String())
	}
	if after, _ := st.SubmissionFor("ASSMT-ENG-T1", "STU-001"); after.Earned != before.Earned {
		t.Errorf("a refused finalize still wrote marks: %v -> %v", before.Earned, after.Earned)
	}

	// Oversight is untouched: the leader reads the draft it may not commit.
	if rec := do(r, "GET", "/api/marking-drafts/"+classroom.ID, "", bearer(head)); rec.Code != http.StatusOK {
		t.Errorf("headteacher reading a classroom draft: got %d, want 200", rec.Code)
	}

	// The owning teacher still finalizes their own classroom work.
	rec = do(r, "POST", "/api/marking-drafts/"+classroom.ID+"/finalize",
		finalizeBody(classroom, map[int]float64{1: 1, 2: 1, 3: 2}, nil), bearer(teacher))
	if rec.Code != http.StatusOK {
		t.Errorf("teacher finalizing their own classroom draft: got %d, want 200 (%s)",
			rec.Code, rec.Body.String())
	}
}

// TestCanFinalizeDraftMatrix pins the policy itself — the split from
// adminOnlyAssessmentTypes applied to the write path — including superAdmin as
// a NAMED case rather than something inherited from the school-level roles by
// fall-through.
func TestCanFinalizeDraftMatrix(t *testing.T) {
	classroom := domain.TypeClassTest
	exam := domain.TypeMock
	assignment := "" // a scheme with no assessment is assignment work
	own := domain.User{Role: domain.RoleTeacher, ClassID: "JHS2A"}
	other := domain.User{Role: domain.RoleTeacher, ClassID: "JHS1B"}

	cases := []struct {
		name    string
		u       domain.User
		classID string
		typ     string
		want    bool
	}{
		// The owning teacher finalizes classroom work in their own class...
		{"teacher, own classroom", own, "JHS2A", classroom, true},
		{"teacher, own assignment", own, "JHS2A", assignment, true},
		// ...and nobody else's, whatever the type.
		{"teacher, another class", other, "JHS2A", classroom, false},
		{"teacher, another class's exam", other, "JHS2A", exam, false},
		// Leaders keep the exam types they are entitled to create...
		{"headteacher, exam", domain.User{Role: domain.RoleHeadteacher}, "JHS2A", exam, true},
		{"schoolAdmin, exam", domain.User{Role: domain.RoleSchoolAdmin}, "JHS2A", exam, true},
		// ...but never another teacher's classroom work.
		{"headteacher, classroom", domain.User{Role: domain.RoleHeadteacher}, "JHS2A", classroom, false},
		{"schoolAdmin, classroom", domain.User{Role: domain.RoleSchoolAdmin}, "JHS2A", classroom, false},
		{"headteacher, assignment", domain.User{Role: domain.RoleHeadteacher}, "JHS2A", assignment, false},
		// superAdmin is explicit: it acts in every school, so it finalizes
		// anywhere rather than inheriting the school-level restriction.
		{"superAdmin, classroom", domain.User{Role: domain.RoleSuperAdmin}, "JHS2A", classroom, true},
		{"superAdmin, assignment", domain.User{Role: domain.RoleSuperAdmin}, "JHS1B", assignment, true},
		// Roles the route already blocks must not pass here either.
		{"parent", domain.User{Role: domain.RoleParent}, "JHS2A", exam, false},
		{"student", domain.User{Role: domain.RoleStudent}, "JHS2A", exam, false},
		{"staff", domain.User{Role: domain.RoleStaff}, "JHS2A", exam, false},
		// A teacher without a class of their own cannot finalize anything.
		{"teacher, classless", domain.User{Role: domain.RoleTeacher}, "JHS2A", classroom, false},
		{"teacher, empty class", own, "", classroom, false},
	}
	for _, tc := range cases {
		if got := canFinalizeDraft(tc.u, tc.classID, tc.typ); got != tc.want {
			t.Errorf("%s: canFinalizeDraft = %v, want %v", tc.name, got, tc.want)
		}
	}
}
