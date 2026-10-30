package store

import (
	"database/sql"
	"os"
	"testing"

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
	if one, _ := ts.For(domain.DefaultSchoolID()); one != def {
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
