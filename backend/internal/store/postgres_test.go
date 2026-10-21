package store

import (
	"os"
	"strings"
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
	// Any storage failure during the test would otherwise be invisible: most
	// callers — this file included — discard what a write returns, so a failed
	// write only surfaces later as an assertion failing for no apparent reason
	// ("students: got 0, want 8"). The Store contract does return errors now,
	// but the latch is what catches a caller that drops one, and it is what
	// tells a real defect apart from a dropped connection: the transport error
	// is reported verbatim instead of arriving as a data mismatch a minute or
	// two later. Expect exactly that against a remote pooler on a bad day.
	before, _, _ := pg.StoreErrors()
	t.Cleanup(func() {
		if after, last, _ := pg.StoreErrors(); after != before {
			t.Errorf("%d storage operation(s) failed and were only logged; last: %v",
				after-before, last)
		}
	})
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
	if len(pg.Users()) != 14 {
		// 6 founding accounts + 7 linked parent accounts (USR-PRN-002..008)
		// + 1 support-staff account, matching seed_test.go.
		t.Fatalf("users: got %d, want 14", len(pg.Users()))
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

	if got := len(pg.Announcements()); got != len(seedAnnouncements) {
		t.Fatalf("announcements: got %d, want %d", got, len(seedAnnouncements))
	}
	// exercise the write path
	pg.AddAnnouncement(domain.Announcement{
		ID: "ANN-X", Title: "Assembly", Body: "Mon 7:30", Audience: domain.AudSchool,
		AuthorID: "USR-ADM-001", Timestamp: "2026-09-21T07:00",
	})
	var added *domain.Announcement
	for _, a := range pg.Announcements() {
		if a.ID == "ANN-X" {
			a := a
			added = &a
		}
	}
	if added == nil {
		t.Fatal("announcement add: ANN-X not stored")
	}
	if added.AuthorName != "Mrs. Adjoa Amankwah" {
		t.Fatalf("announcement author name not joined: %+v", *added)
	}
}

// TestPostgresSeedPreservesRuntimeAttendance is the PostgreSQL half of
// TestSeedNeverDeletesRecordedAttendance: attendance recorded outside the seed
// must survive a re-seed. SaveAttendance previously deleted every row whose id
// was not in the seed set, so restarting with seed=true wiped real data.
func TestPostgresSeedPreservesRuntimeAttendance(t *testing.T) {
	pg := postgresTest(t)
	Seed(pg)

	live := domain.AttendanceRecord{
		ID: "ATT-LIVE-PG", StudentID: "STU-001", ClassID: "JHS2A",
		Date: "2030-01-01", Status: domain.AttPresent, CheckIn: "07:45",
	}
	pg.SaveDay("JHS2A", live.Date, []domain.AttendanceRecord{live})
	before := len(pg.Attendance())

	Seed(pg)
	Seed(pg)

	if got := len(pg.Attendance()); got != before {
		t.Fatalf("attendance: got %d, want %d (seed removed runtime rows)", got, before)
	}
	day := pg.AttendanceForClassDate("JHS2A", live.Date)
	if len(day) != 1 || day[0].ID != live.ID {
		t.Fatalf("runtime record lost: %+v", day)
	}
}

func TestPostgresWritePaths(t *testing.T) {
	pg := postgresTest(t)
	Seed(pg) // tests share one database; the seed is idempotent

	// SaveDay replaces one class/date bucket, keeping other days intact
	att := pg.Attendance()
	if len(att) == 0 {
		// An empty table here means the seed's writes failed. Seed discards
		// what SaveAttendance returns — postgresTest's cleanup reports the
		// latch — so on its own this surfaces only as a confusing
		// index-out-of-range further down.
		t.Fatal("attendance empty after Seed(pg); a write failed and was not checked")
	}
	total := len(att)
	firstDay := att[0].Date
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

	// a replayed payment is stored once: the device pushes payment.record until
	// it gets an answer, so SavePayment is handed the identical id again after
	// a timeout. ON CONFLICT (id) DO NOTHING must swallow it — two rows would
	// double-bill the same collection. StudentID travels with it (003), which
	// is what lets a read be scoped per student without resolving invoices.
	pay := domain.Payment{
		ID: "PAY-T", InvoiceID: "INV-T", StudentID: "STU-001", Amount: 250,
		Method: "cash", Reference: "RCPT-9", PaidAt: "2026-10-01 09:41", RecordedBy: "Bursar",
	}
	if err := pg.SavePayment(pay); err != nil {
		t.Fatalf("SavePayment: %v", err)
	}
	if err := pg.SavePayment(pay); err != nil {
		t.Fatalf("SavePayment replay: %v", err)
	}
	n := 0
	for _, p := range pg.Payments() {
		if p.ID == "PAY-T" {
			n++
			if p.Amount != 250 || p.InvoiceID != "INV-T" || p.Method != "cash" ||
				p.StudentID != "STU-001" {
				t.Fatalf("stored payment wrong: %+v", p)
			}
		}
	}
	if n != 1 {
		t.Fatalf("replayed payment stored %d times, want 1", n)
	}

	// invoices: the JSONB line items and the ::text dates must round-trip, an
	// upsert must not duplicate, and the amount must be SUMMED from the
	// payment above rather than read back — no amount_paid column exists.
	inv := domain.Invoice{
		ID: "INV-T", StudentID: "STU-001", IssueDate: "2026-09-07",
		DueDate: "2026-10-07", Term: "Term 1 · 2026/2027",
		LineItems: []domain.FeeLineItem{{Name: "Tuition — JHS2A", Amount: 1000}},
	}
	if err := pg.SaveInvoice(inv); err != nil {
		t.Fatalf("SaveInvoice: %v", err)
	}
	if err := pg.SaveInvoice(inv); err != nil {
		t.Fatalf("SaveInvoice replay: %v", err)
	}
	// A corrected bill replaces the terms rather than adding a second invoice.
	inv.LineItems = append(inv.LineItems, domain.FeeLineItem{Name: "Trip levy", Amount: 250})
	if err := pg.SaveInvoice(inv); err != nil {
		t.Fatalf("SaveInvoice correction: %v", err)
	}
	stored := 0
	for _, g := range pg.Invoices() {
		if g.ID != "INV-T" {
			continue
		}
		stored++
		if len(g.LineItems) != 2 || g.LineItems[0].Name != "Tuition — JHS2A" ||
			g.LineItems[1].Amount != 250 || g.Term != "Term 1 · 2026/2027" ||
			g.IssueDate != "2026-09-07" || g.DueDate != "2026-10-07" {
			t.Fatalf("invoice did not round-trip: %+v", g)
		}
		if g.AmountPaid != 250 {
			t.Fatalf("amountPaid = %d, want 250 — summed from the payment above, "+
				"not stored on the invoice", g.AmountPaid)
		}
		if g.Status == "" {
			t.Fatal("status not derived on read")
		}
	}
	if stored != 1 {
		t.Fatalf("invoice stored %d times after upsert, want 1", stored)
	}
	if len(pg.Invoices()) < 8 {
		t.Fatalf("seed raised %d invoices, want the 8 one-per-student bills", len(pg.Invoices()))
	}

	// school/term upserts are idempotent
	pg.SaveSchool(pg.School())
	pg.SaveTerm(pg.Term())
	if pg.School().Name == "" || pg.Term().Name == "" {
		t.Fatal("school/term lost after upsert")
	}
}

func TestPostgresRecordsReadsAndReceipts(t *testing.T) {
	pg := postgresTest(t)
	Seed(pg)

	if got := len(pg.Records(domain.RecordLessons)); got != 25 {
		t.Errorf("seeded lessons = %d, want 25", got)
	}
	// re-seeding must not overwrite an edited row
	edited := domain.Record{Kind: domain.RecordLessons, ID: "SLOT-0-0", ClassID: "JHS2A",
		UpdatedAt: "2026-10-21 09:00", Data: []byte(`{"id":"SLOT-0-0","edited":true}`)}
	if err := pg.SaveRecord(edited); err != nil {
		t.Fatal(err)
	}
	Seed(pg)
	if r, ok := pg.RecordByID(domain.RecordLessons, "SLOT-0-0"); !ok || !strings.Contains(string(r.Data), "edited") {
		t.Errorf("seed overwrote an edited slot: %s", r.Data)
	}

	scan := domain.Record{Kind: domain.RecordScans, ID: "SCAN-PG", StudentID: "STU-001",
		UpdatedAt: "2026-10-21 09:00", Data: []byte(`{"id":"SCAN-PG","studentId":"STU-001"}`)}
	if err := pg.SaveRecord(scan); err != nil {
		t.Fatal(err)
	}
	img := []byte{0xFF, 0xD8, 0x00, 0x01}
	if err := pg.SaveScanImage("SCAN-PG", "image/jpeg", img); err != nil {
		t.Fatal(err)
	}
	if ct, data, ok := pg.ScanImage("SCAN-PG"); !ok || ct != "image/jpeg" || string(data) != string(img) {
		t.Errorf("scan image round trip: %v %q %v", ok, ct, data)
	}
	if err := pg.DeleteRecord(domain.RecordScans, "SCAN-PG"); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := pg.ScanImage("SCAN-PG"); ok {
		t.Error("deleting a scan left its image behind")
	}

	if err := pg.MarkNotificationReadBy("NOTIF-001", "USR-PRN-001"); err != nil {
		t.Fatal(err)
	}
	if err := pg.MarkNotificationReadBy("NOTIF-001", "USR-PRN-001"); err != nil {
		t.Fatalf("marking twice: %v", err)
	}
	if !pg.NotificationReadsBy("USR-PRN-001")["NOTIF-001"] || pg.NotificationReadsBy("USR-OTHER")["NOTIF-001"] {
		t.Error("per-reader read state is wrong")
	}

	msgs := pg.Messages()
	if len(msgs) == 0 {
		t.Fatal("no seeded messages")
	}
	id := msgs[0].ID
	if err := pg.SetMessageReceipt(id, "2026-10-21 09:00", ""); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetMessageReceipt(id, "2026-10-21 10:00", "2026-10-21 10:00"); err != nil {
		t.Fatal(err)
	}
	for _, m := range pg.Messages() {
		if m.ID == id && (m.DeliveredAt != "2026-10-21 09:00" || m.ReadAt != "2026-10-21 10:00" || !m.Read) {
			t.Errorf("receipt stamps: %+v", m)
		}
	}
	if n, last, _ := pg.StoreErrors(); n > 0 {
		t.Errorf("%d storage errors, last: %v", n, last)
	}
}
