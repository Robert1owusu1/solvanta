package store

import (
	"os"
	"testing"

	"solvanta/backend/internal/domain"
)

// postgresTest returns a Postgres store when TEST_POSTGRES_DSN is set, else
// nil with a "skip" signal so the suite runs in CI against a real database.
func postgresTest(t *testing.T) *Postgres {
	t.Helper()
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN not set; skipping PostgreSQL integration tests")
	}
	pg, err := NewPostgres(dsn, false)
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(func() { pg.Close() })
	// The database is shared between runs/workers; start from a clean slate so
	// every test asserts against the seed alone.
	if _, err := pg.db.ExecContext(t.Context(),
		`DO $$ DECLARE r record;
		 BEGIN
		   FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
		     EXECUTE format('TRUNCATE %I CASCADE', r.tablename);
		   END LOOP;
		 END $$`); err != nil {
		t.Fatalf("reset schema: %v", err)
	}
	return pg
}

func TestPostgresSeedRoundTrip(t *testing.T) {
	pg := postgresTest(t)

	// idempotent: applying the seed twice must not duplicate/conflict
	Seed(pg)
	Seed(pg)

	if len(pg.Students()) != 8 {
		t.Fatalf("students: got %d, want 8", len(pg.Students()))
	}
	if len(pg.Classes()) != 6 {
		t.Fatalf("classes: got %d, want 6", len(pg.Classes()))
	}
	if len(pg.Users()) != 13 {
		// 6 founding accounts + 7 linked parent accounts (USR-PRN-002..008),
		// matching the in-memory seed asserted in seed_test.go.
		t.Fatalf("users: got %d, want 13", len(pg.Users()))
	}

	kojo, ok := pg.StudentByID("STU-001")
	if !ok {
		t.Fatal("STU-001 missing after seed")
	}
	if kojo.FullName() != "Kojo Owusu" {
		t.Fatalf("STU-001 name: %q", kojo.FullName())
	}
	if len(kojo.Guardians) != 2 || len(kojo.EmergencyContacts) != 1 || len(kojo.AuthorizedPickup) != 2 {
		t.Fatalf("STU-001 contacts mismatch: g=%d e=%d p=%d",
			len(kojo.Guardians), len(kojo.EmergencyContacts), len(kojo.AuthorizedPickup))
	}

	u, ok := pg.UserByEmail("efua.mensah@school.gh")
	if !ok {
		t.Fatal("teacher missing after seed")
	}
	if u.Role != domain.RoleTeacher || u.ClassID != "JHS2A" {
		t.Fatalf("teacher payload: %+v", u)
	}
	if u.Password == "" || u.Password == "teacher123" {
		t.Fatal("password not stored hashed")
	}

	parent, ok := pg.UserByEmail("ama.owusu@school.gh")
	if !ok || len(parent.StudentIDs) != 1 || parent.StudentIDs[0] != "STU-001" {
		t.Fatalf("parent link broken: %+v", parent)
	}

	if len(pg.Questions()) != 10 {
		t.Fatalf("question bank: got %d, want 10", len(pg.Questions()))
	}
	mcq, _ := pg.QuestionByID("Q-MATH-001")
	if len(mcq.Options) != 4 || mcq.Options[0] != "2/4" || mcq.Marks != 2 {
		t.Fatalf("MCQ payload wrong: %+v", mcq)
	}

	if len(pg.Assessments()) != 4 {
		t.Fatalf("assessments: got %d, want 4", len(pg.Assessments()))
	}
	half, ok := pg.AssessmentByID("ASSMT-MAT-HALF")
	if !ok || len(half.Questions) != 3 || half.Questions[2].ID != "Q-MATH-003" {
		t.Fatalf("assessment questions wrong: %+v", half)
	}

	sub, ok := pg.SubmissionFor("ASSMT-MAT-HALF", "STU-001")
	if !ok || sub.Earned != 8 || sub.Answers["Q-MATH-002"] != "3/8 m" || sub.TeacherMarks["Q-MATH-003"] != 3 {
		t.Fatalf("submission payload wrong: %+v", sub)
	}

	if len(pg.Attendance()) != 30 {
		t.Fatalf("attendance: got %d, want 30", len(pg.Attendance()))
	}
	day := pg.AttendanceForClassDate("JHS2A", pg.Attendance()[0].Date)
	if len(day) != 6 {
		t.Fatalf("day records: got %d, want 6", len(day))
	}

	if len(pg.GateEvents()) != 5 {
		t.Fatalf("gate events: got %d, want 5", len(pg.GateEvents()))
	}
	if len(pg.Interventions()) != 1 {
		t.Fatalf("interventions: got %d, want 1", len(pg.Interventions()))
	}
	if len(pg.Messages()) != 3 {
		t.Fatalf("messages: got %d, want 3", len(pg.Messages()))
	}
	if len(pg.Notifications()) != 3 {
		t.Fatalf("notifications: got %d, want 3", len(pg.Notifications()))
	}
	if len(pg.Assignments()) != 2 {
		t.Fatalf("assignments: got %d, want 2", len(pg.Assignments()))
	}

	ann := pg.Announcements()
	if len(ann) != 0 {
		t.Fatalf("announcements: got %d, want 0 (seed has none)", len(ann))
	} else {
		// exercise the write path
		pg.AddAnnouncement(domain.Announcement{
			ID: "ANN-X", Title: "Assembly", Body: "Mon 7:30", Audience: domain.AudSchool,
			AuthorID: "USR-ADM-001", Timestamp: "2026-09-21T07:00",
		})
		if got := len(pg.Announcements()); got != 1 {
			t.Fatalf("announcement add: got %d, want 1", got)
		}
		if pg.Announcements()[0].AuthorName != "Mrs. Adjoa Amankwah" {
			t.Fatalf("announcement author name not joined: %+v", pg.Announcements()[0])
		}
	}
}

func TestPostgresWritePaths(t *testing.T) {
	pg := postgresTest(t)
	Seed(pg) // tests share one database; the seed is idempotent

	// SaveDay replaces one class/date bucket, keeping other days intact
	total := len(pg.Attendance())
	firstDay := pg.Attendance()[0].Date
	pg.SaveDay("JHS2A", firstDay, []domain.AttendanceRecord{
		{ID: "ATT-X1", StudentID: "STU-001", ClassID: "JHS2A", Date: firstDay, Status: domain.AttLate, CheckIn: "08:01"},
		{ID: "ATT-X2", StudentID: "STU-003", ClassID: "JHS2A", Date: firstDay, Status: domain.AttPresent, CheckIn: "07:30"},
	})
	out := pg.AttendanceForClassDate("JHS2A", firstDay)
	if len(out) != 2 {
		t.Fatalf("SaveDay bucket: got %d, want 2", len(out))
	}
	// other attendance days untouched
	rest := total - 6 + 2 // replaced 6 with 2
	if len(pg.Attendance()) != rest {
		t.Fatalf("SaveDay leaked outside bucket: got %d, want %d", len(pg.Attendance()), rest)
	}

	// user upsert + link rewrite
	pg.SaveUser(domain.User{
		ID: "USR-TEST", Name: "Test Teacher", Email: "t@school.gh", Password: "x",
		Role: domain.RoleTeacher, SchoolID: "SCH-001", ClassID: "JHS1A",
		StudentIDs: []string{"STU-001", "STU-002"},
	})
	u, ok := pg.UserByEmail("t@school.gh")
	if !ok || len(u.StudentIDs) != 2 {
		t.Fatalf("user upsert/link: %+v", u)
	}
	pg.SaveUser(domain.User{
		ID: "USR-TEST", Name: "Test Teacher", Email: "t@school.gh", Password: "x",
		Role: domain.RoleTeacher, SchoolID: "SCH-001", ClassID: "JHS1A",
		StudentIDs: []string{"STU-001"},
	})
	u, _ = pg.UserByEmail("t@school.gh")
	if len(u.StudentIDs) != 1 {
		t.Fatalf("user link rewrite: %+v", u.StudentIDs)
	}

	// assignment completions
	pg.SaveAssignment(domain.Assignment{
		ID: "ASG-T", ClassID: "JHS2A", SubjectID: "MATH", Title: "T", Deadline: "2026-10-01",
		CompletedBy: []string{"STU-001", "STU-002"},
	})
	a, ok := pg.AssignmentByID("ASG-T")
	if !ok || len(a.CompletedBy) != 2 {
		t.Fatalf("assignment completions: %+v", a)
	}

	// notification read + add
	pg.AddNotification(domain.Notification{ID: "NOTIF-X", Kind: domain.NotifSystem, Title: "T", Body: "B", Timestamp: "2026-09-21 09:00"})
	pg.SetNotificationRead("NOTIF-X")
	found := false
	for _, n := range pg.Notifications() {
		if n.ID == "NOTIF-X" {
			found = true
			if !n.Read {
				t.Fatal("notification not marked read")
			}
		}
	}
	if !found {
		t.Fatal("added notification missing")
	}

	// message ordering must keep seeded messages
	if len(pg.Messages()) != 3 {
		t.Fatalf("messages after seed reset: got %d", len(pg.Messages()))
	}

	// refresh tokens
	pg.SaveRefreshToken("hashabc", "USR-STU-001", 1234567890)
	if uid, exp, ok := pg.RefreshTokenLookup("hashabc"); !ok || uid != "USR-STU-001" || exp != 1234567890 {
		t.Fatalf("refresh token lookup: %q %d %v", uid, exp, ok)
	}
	pg.DeleteRefreshToken("hashabc")
	if _, _, ok := pg.RefreshTokenLookup("hashabc"); ok {
		t.Fatal("refresh token not deleted")
	}

	// audit is append-only
	before := len(pg.AuditLogs())
	pg.AddAudit(domain.AuditEntry{Action: "user.create", Actor: "USR-ADM-001", Target: "USR-TEST", Detail: "x", Timestamp: "2026-09-21T09:00"})
	if len(pg.AuditLogs()) != before+1 {
		t.Fatal("audit append failed")
	}

	// school/term upserts are idempotent
	pg.SaveSchool(pg.School())
	pg.SaveTerm(pg.Term())
	if pg.School().Name == "" || pg.Term().Name == "" {
		t.Fatal("school/term lost after upsert")
	}
}
