package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"solvanta/backend/internal/domain"
)

// =============================================================================
// Marking scheme RBAC — who may read and write the answer key
// =============================================================================
//
// A scheme carries every accepted answer, so it is gated tighter than the
// assessment it belongs to: school leaders for any class, a teacher only for
// the class they teach, exam types for leaders only, and nobody else — not
// staff, not parents, not students — reads it at all.

// otherClass is a class the seeded teacher (JHS2A) does not teach.
const otherClass = "JHS1B"

// seedOtherClassTargets adds an assessment and an assignment for otherClass so
// the "not your class" cases have something real to point at.
func seedOtherClassTargets(t *testing.T, st interface {
	SaveAssessment(domain.Assessment) error
	SaveAssignment(domain.Assignment) error
}) {
	t.Helper()
	if err := st.SaveAssessment(domain.Assessment{ID: "ASSMT-OTHER", Title: "Other class test",
		Type: domain.TypeClassTest, SubjectID: "MATH", ClassID: otherClass}); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveAssignment(domain.Assignment{ID: "ASG-OTHER", Title: "Other class homework",
		SubjectID: "MATH", ClassID: otherClass}); err != nil {
		t.Fatal(err)
	}
}

func schemeBody(field, id string) string {
	return fmt.Sprintf(`{%q:%q,"questions":%s}`, field, id, schemeQuestionsFixture)
}

func TestSchemeCreateRoleMatrix(t *testing.T) {
	cases := []struct {
		name, email, pw, path, field, id string
		want                             int
	}{
		// Assignments: the teacher's own class, and any class for leaders.
		{"teacher own assignment", "efua.mensah@school.gh", "teacher123", "/api/assignments/ASG-001/marking-scheme", "assignmentId", "ASG-001", http.StatusCreated},
		{"head assignment", "head@school.gh", "head123", "/api/assignments/ASG-001/marking-scheme", "assignmentId", "ASG-001", http.StatusCreated},
		{"admin other-class assignment", "admin@solvanta.app", "admin123", "/api/assignments/ASG-OTHER/marking-scheme", "assignmentId", "ASG-OTHER", http.StatusCreated},
		{"teacher other-class assignment", "efua.mensah@school.gh", "teacher123", "/api/assignments/ASG-OTHER/marking-scheme", "assignmentId", "ASG-OTHER", http.StatusForbidden},

		// Class tests: the teacher's own class only.
		{"teacher own class test", "efua.mensah@school.gh", "teacher123", "/api/assessments/ASSMT-ENG-T1/marking-scheme", "assessmentId", "ASSMT-ENG-T1", http.StatusCreated},
		{"teacher other-class test", "efua.mensah@school.gh", "teacher123", "/api/assessments/ASSMT-OTHER/marking-scheme", "assessmentId", "ASSMT-OTHER", http.StatusForbidden},

		// Exam types stay admin-only, even in the teacher's own class.
		{"teacher mock exam", "efua.mensah@school.gh", "teacher123", "/api/assessments/ASSMT-MOCK-BECE-MATH/marking-scheme", "assessmentId", "ASSMT-MOCK-BECE-MATH", http.StatusForbidden},
		{"head mock exam", "head@school.gh", "head123", "/api/assessments/ASSMT-MOCK-BECE-MATH/marking-scheme", "assessmentId", "ASSMT-MOCK-BECE-MATH", http.StatusCreated},

		// Never staff, parents or students.
		{"staff", "staff@school.gh", "staff123", "/api/assignments/ASG-001/marking-scheme", "assignmentId", "ASG-001", http.StatusForbidden},
		{"parent", "ama.owusu@school.gh", "parent123", "/api/assignments/ASG-001/marking-scheme", "assignmentId", "ASG-001", http.StatusForbidden},
		{"student", "kojo.owusu@school.gh", "student123", "/api/assignments/ASG-001/marking-scheme", "assignmentId", "ASG-001", http.StatusForbidden},

		// The body may not retarget the write away from the URL.
		{"body names another target", "efua.mensah@school.gh", "teacher123", "/api/assignments/ASG-001/marking-scheme", "assignmentId", "ASG-OTHER", http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, st := newTestServerWithStore(t, Config{})
			seedOtherClassTargets(t, st)
			tok := login(t, r, tc.email, tc.pw)
			rec := do(r, "POST", tc.path, schemeBody(tc.field, tc.id),
				map[string]string{"Authorization": "Bearer " + tok})
			if rec.Code != tc.want {
				t.Fatalf("got %d, want %d: %s", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}

// TestSchemeReadsHideTheAnswerKey is the regression guard for students and
// parents being able to download every accepted answer for their class.
func TestSchemeReadsHideTheAnswerKey(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	seedOtherClassTargets(t, st)
	head := login(t, r, "head@school.gh", "head123")
	own := createScheme(t, r, head, "ASSMT-MAT-HALF")
	other := createScheme(t, r, head, "ASSMT-OTHER")

	type read struct {
		path string
		want int
	}
	reads := func(id, assessment string, want int) []read {
		return []read{
			{"/api/marking-schemes/" + id, want},
			{"/api/assessments/" + assessment + "/marking-scheme", want},
		}
	}
	cases := []struct {
		name, email, pw string
		reads           []read
		listLen         int
	}{
		{"head", "head@school.gh", "head123",
			append(reads(own.ID, "ASSMT-MAT-HALF", 200), reads(other.ID, "ASSMT-OTHER", 200)...), 2},
		{"teacher", "efua.mensah@school.gh", "teacher123",
			append(reads(own.ID, "ASSMT-MAT-HALF", 200), reads(other.ID, "ASSMT-OTHER", 403)...), 1},
		{"staff", "staff@school.gh", "staff123", reads(own.ID, "ASSMT-MAT-HALF", 403), 0},
		{"parent", "ama.owusu@school.gh", "parent123", reads(own.ID, "ASSMT-MAT-HALF", 403), 0},
		{"student", "kojo.owusu@school.gh", "student123", reads(own.ID, "ASSMT-MAT-HALF", 403), 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			hdr := map[string]string{"Authorization": "Bearer " + login(t, r, tc.email, tc.pw)}
			for _, rd := range tc.reads {
				if rec := do(r, "GET", rd.path, "", hdr); rec.Code != rd.want {
					t.Errorf("GET %s: got %d, want %d", rd.path, rec.Code, rd.want)
				}
			}
			var list []domain.MarkingScheme
			rec := do(r, "GET", "/api/marking-schemes", "", hdr)
			if rec.Code != http.StatusOK {
				t.Fatalf("list: got %d", rec.Code)
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
				t.Fatalf("decode list: %v", err)
			}
			if len(list) != tc.listLen {
				t.Errorf("list: got %d schemes, want %d", len(list), tc.listLen)
			}
		})
	}
}

// TestSchemeEditAndDeleteFollowCreateRule checks a teacher cannot edit or
// delete another class's scheme, while a leader can.
func TestSchemeEditAndDeleteFollowCreateRule(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	seedOtherClassTargets(t, st)
	head := login(t, r, "head@school.gh", "head123")
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	other := createScheme(t, r, head, "ASSMT-OTHER")
	put := fmt.Sprintf(`{"questions":%s}`, schemeQuestionsFixture)

	teacherHdr := map[string]string{"Authorization": "Bearer " + teacher}
	if rec := do(r, "PUT", "/api/marking-schemes/"+other.ID, put, teacherHdr); rec.Code != http.StatusForbidden {
		t.Errorf("teacher edit other class: got %d, want 403", rec.Code)
	}
	if rec := do(r, "DELETE", "/api/marking-schemes/"+other.ID, "", teacherHdr); rec.Code != http.StatusForbidden {
		t.Errorf("teacher delete other class: got %d, want 403", rec.Code)
	}
	headHdr := map[string]string{"Authorization": "Bearer " + head}
	if rec := do(r, "DELETE", "/api/marking-schemes/"+other.ID, "", headHdr); rec.Code >= 300 {
		t.Errorf("head delete: got %d %s", rec.Code, rec.Body.String())
	}
}
