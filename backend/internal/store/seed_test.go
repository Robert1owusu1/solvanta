package store

import (
	"testing"

	"golang.org/x/crypto/bcrypt"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/marking"
)

func seedCounts(t *testing.T) map[string]int {
	t.Helper()
	m := New()
	return map[string]int{
		"users":         len(m.Users()),
		"classes":       len(m.Classes()),
		"students":      len(m.Students()),
		"questions":     len(m.Questions()),
		"assessments":   len(m.Assessments()),
		"submissions":   len(m.Submissions()),
		"attendance":    len(m.Attendance()),
		"gate":          len(m.GateEvents()),
		"interventions": len(m.Interventions()),
		"messages":      len(m.Messages()),
		"notifications": len(m.Notifications()),
		"assignments":   len(m.Assignments()),
	}
}

func TestSeedContents(t *testing.T) {
	counts := seedCounts(t)
	want := map[string]int{
		"users": 6, "classes": 6, "students": 8, "questions": 10,
		"assessments": 4, "submissions": 3, "attendance": 30, "gate": 5,
		"interventions": 1, "messages": 3, "notifications": 3, "assignments": 2,
	}
	for k, w := range want {
		if counts[k] != w {
			t.Fatalf("%s = %d, want %d", k, counts[k], w)
		}
	}
}

// TestSubmittedEarnedMatchesMarking re-derives each seeded submission's earned
// total with the marking engine — the seed must agree with the engine.
func TestSubmittedEarnedMatchesMarking(t *testing.T) {
	m := New()
	for _, sub := range m.Submissions() {
		if sub.ID == "SUB-E1-STU001" {
			continue // app-seed inconsistency, asserted below
		}
		a, ok := m.AssessmentByID(sub.AssessmentID)
		if !ok {
			t.Fatalf("submission %s references unknown assessment %s", sub.ID, sub.AssessmentID)
		}
		got := marking.ComputeEarned(a.Questions, sub.Answers, sub.TeacherMarks)
		if got != sub.Earned {
			t.Fatalf("%s: compute = %v, seed earned = %v", sub.ID, got, sub.Earned)
		}
	}
}

// TestAppSeedInconsistencyDocumentsClientParity: the Flutter seed stores
// SUB-E1-STU001 earned=6 but only marks Q-ENG-003; Q-ENG-002 (fillBlank) is
// subjective so recompute yields 4. The backend mirrors the client data
// verbatim — the fillBlank verdict lands during marking.
func TestAppSeedInconsistencyDocumentsClientParity(t *testing.T) {
	m := New()
	sub, ok := m.SubmissionFor("ASSMT-ENG-T1", "STU-001")
	if !ok {
		t.Fatal("missing SUB-E1-STU001")
	}
	if sub.Earned != 6 {
		t.Fatalf("seed earned = %v, want 6 (as stored in the app)", sub.Earned)
	}
	a, _ := m.AssessmentByID("ASSMT-ENG-T1")
	if got := marking.ComputeEarned(a.Questions, sub.Answers, sub.TeacherMarks); got != 4 {
		t.Fatalf("recompute = %v, want 4 until the fillBlank verdict is given", got)
	}
}

func TestAttendanceSeedPerStudent(t *testing.T) {
	m := New()
	var total int
	for _, r := range m.Attendance() {
		if r.ClassID != "JHS2A" {
			t.Fatalf("record %s outside JHS2A", r.ID)
		}
		total++
	}
	if total != 30 {
		t.Fatalf("attendance rows = %d, want 30", total)
	}
	var st1 int
	for _, r := range m.Attendance() {
		if r.StudentID == "STU-001" {
			st1++
		}
	}
	if st1 != 5 {
		t.Fatalf("STU-001 has %d attendance rows, want 5", st1)
	}
}

func TestLoginDemoUsers(t *testing.T) {
	m := New()
	for email, pw := range map[string]string{
		"admin@solvanta.app": "admin123", "efua.mensah@school.gh": "teacher123",
		"ama.owusu@school.gh": "parent123", "kojo.owusu@school.gh": "student123",
	} {
		u, ok := m.UserByEmail(email)
		if !ok {
			t.Fatalf("missing demo user %s", email)
		}
		if u.Password == pw {
			t.Fatalf("%s: password stored in plaintext", email)
		}
		if err := bcrypt.CompareHashAndPassword([]byte(u.Password), []byte(pw)); err != nil {
			t.Fatalf("%s: stored hash does not verify: %v", email, err)
		}
	}
	_ = domain.DefaultSchoolID()
}
