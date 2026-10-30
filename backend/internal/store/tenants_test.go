package store

import (
	"database/sql"
	"os"
	"testing"
	"time"

	"solvanta/backend/internal/domain"
	"solvanta/backend/migrations"
)

func TestMemoryTenantsAreSeparate(t *testing.T) {
	ts := NewMemoryTenants(New())
	two, err := ts.Create("SCH-002")
	if err != nil {
		t.Fatal(err)
	}
	if len(two.Students()) != 0 {
		t.Fatal("a new school starts empty")
	}
	if _, err := ts.Create("SCH-002"); err != ErrSchoolExists {
		t.Fatalf("re-create: %v", err)
	}
	if _, err := ts.Create("bad id!"); err == nil {
		t.Fatal("an id that can't name a schema was accepted")
	}
	if _, err := ts.For("SCH-404"); err != ErrUnknownSchool {
		t.Fatalf("unknown school: %v", err)
	}
	def, _ := ts.For("")
	if one, _ := ts.For(domain.DefaultSchoolID()); Unwrap(one) != Unwrap(def) {
		t.Fatal("the empty school id is the default school")
	}
}

// Each school is its own PostgreSQL schema: same tables, separate rows, and
// migrations recorded once per schema.
func TestPostgresTenantsAreSeparateSchemas(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN not set; skipping PostgreSQL integration tests")
	}
	raw, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	for _, q := range []string{
		`DROP SCHEMA IF EXISTS school_sch_001 CASCADE`,
		`DROP SCHEMA IF EXISTS school_t_two CASCADE`,
		`DROP TABLE IF EXISTS public.tenants`,
	} {
		if _, err := raw.Exec(q); err != nil {
			t.Fatal(err)
		}
	}

	ts, err := NewPostgresTenants(dsn, true)
	if err != nil {
		t.Fatalf("NewPostgresTenants: %v", err)
	}
	defer ts.Close()
	one, err := ts.For("")
	if err != nil {
		t.Fatal(err)
	}
	if len(one.Students()) == 0 {
		t.Fatal("the default school was not seeded")
	}
	two, err := ts.Create("T-TWO")
	if err != nil {
		t.Fatal(err)
	}
	if len(two.Students()) != 0 {
		t.Fatal("a new school's schema starts empty")
	}
	if err := two.SaveSchool(domain.School{ID: "T-TWO", Name: "Two"}); err != nil {
		t.Fatal(err)
	}
	if one.School().Name == "Two" {
		t.Fatal("school two's profile landed in school one")
	}

	var n int
	if err := raw.QueryRow(`SELECT count(*) FROM school_t_two.schema_migrations`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != len(migrations.Files()) {
		t.Fatalf("school two recorded %d migrations, want %d", n, len(migrations.Files()))
	}

	// A restart finds both schools and re-applies nothing.
	ts.Close()
	again, err := NewPostgresTenants(dsn, false)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if got := again.Schools(); len(got) != 2 {
		t.Fatalf("schools after restart: %v", got)
	}
	reopened, err := again.For("T-TWO")
	if err != nil || reopened.School().Name != "Two" {
		t.Fatalf("school two after restart: %v %+v", err, reopened)
	}
	if err := raw.QueryRow(`SELECT count(*) FROM school_t_two.schema_migrations`).Scan(&n); err != nil || n != len(migrations.Files()) {
		t.Fatalf("migrations re-applied: %d (%v)", n, err)
	}
}

func TestEmailsClaimOneAccountAcrossSchools(t *testing.T) {
	ts := NewMemoryTenants(New())
	two, _ := ts.Create("SCH-002")
	if err := two.SaveUser(domain.User{ID: "U2", Email: "Efua.Mensah@school.gh", SchoolID: "SCH-002"}); err != ErrEmailTaken {
		t.Fatalf("an email another school uses: %v", err)
	}
	if err := two.SaveUser(domain.User{ID: "U2", Email: "new@two.gh", SchoolID: "SCH-002"}); err != nil {
		t.Fatal(err)
	}
	// Re-saving the same account (a password change) is fine.
	if err := two.SaveUser(domain.User{ID: "U2", Email: "new@two.gh", SchoolID: "SCH-002"}); err != nil {
		t.Fatal(err)
	}
	if school, ok := ts.SchoolForEmail("NEW@two.gh"); !ok || school != "SCH-002" {
		t.Fatalf("directory: %q %v", school, ok)
	}
	if err := ts.Delete(domain.DefaultSchoolID()); err != ErrDefaultSchool {
		t.Fatalf("deleting the default school: %v", err)
	}
}

// Same rules on PostgreSQL, plus idle pools closing and reopening.
func TestPostgresDirectorySuspensionAndIdlePools(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN not set; skipping PostgreSQL integration tests")
	}
	raw, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	for _, q := range []string{
		`DROP SCHEMA IF EXISTS school_sch_001 CASCADE`, `DROP SCHEMA IF EXISTS school_t_two CASCADE`,
		`DROP TABLE IF EXISTS public.tenants`, `DROP TABLE IF EXISTS public.user_directory`,
	} {
		if _, err := raw.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	ts, err := NewPostgresTenants(dsn, true)
	if err != nil {
		t.Fatal(err)
	}
	defer ts.Close()
	if school, ok := ts.SchoolForEmail("efua.mensah@school.gh"); !ok || school != domain.DefaultSchoolID() {
		t.Fatalf("seeded accounts not in the directory: %q %v", school, ok)
	}
	two, err := ts.Create("T-TWO")
	if err != nil {
		t.Fatal(err)
	}
	if err := two.SaveUser(domain.User{ID: "U2", Email: "efua.mensah@school.gh", Name: "x", Role: "teacher", SchoolID: "T-TWO"}); err != ErrEmailTaken {
		t.Fatalf("duplicate email on PostgreSQL: %v", err)
	}
	if err := ts.SetSuspended("T-TWO", true); err != nil || !ts.Suspended("T-TWO") {
		t.Fatalf("suspend: %v", err)
	}

	// Idle pools close, and reopen on the next use.
	ts.IdleAfter = time.Minute
	if n := ts.CloseIdle(time.Now().Add(2 * time.Minute)); n == 0 || ts.OpenPools() != 0 {
		t.Fatalf("closed %d pools, %d still open", n, ts.OpenPools())
	}
	again, err := ts.For("T-TWO")
	if err != nil || len(again.Students()) != 0 || ts.OpenPools() != 1 {
		t.Fatalf("reopen: %v, %d open", err, ts.OpenPools())
	}

	if err := ts.Delete("T-TWO"); err != nil {
		t.Fatal(err)
	}
	var schemas int
	_ = raw.QueryRow(`SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'school_t_two'`).Scan(&schemas)
	if schemas != 0 || len(ts.Schools()) != 1 {
		t.Fatalf("delete left schema=%d schools=%v", schemas, ts.Schools())
	}
}
