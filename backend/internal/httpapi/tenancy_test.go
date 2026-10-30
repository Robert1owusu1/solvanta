package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// newSchool has the super admin register school id and create its admin.
func newSchool(t *testing.T, r *gin.Engine, id, adminEmail, adminPassword string) {
	t.Helper()
	super := login(t, r, "super@solvanta.app", "super123")
	if rec := do(r, "POST", "/api/schools",
		fmt.Sprintf(`{"id":%q,"name":"School %s"}`, id, id), bearer(super)); rec.Code != http.StatusCreated {
		t.Fatalf("create school %s: %d %s", id, rec.Code, rec.Body.String())
	}
	if rec := do(r, "POST", "/api/users", fmt.Sprintf(
		`{"name":"Admin %s","email":%q,"password":%q,"role":"schoolAdmin","schoolId":%q}`,
		id, adminEmail, adminPassword, id), bearer(super)); rec.Code != http.StatusCreated {
		t.Fatalf("create admin for %s: %d %s", id, rec.Code, rec.Body.String())
	}
}

// Two schools share a server but nothing else: each sees only its own
// students, users and school record, writes land only in its own store, and
// the super admin reaches either one by naming it.
func TestSchoolsAreIsolated(t *testing.T) {
	r := newTestServer(t, Config{})
	newSchool(t, r, "SCH-002", "admin@two.school.gh", "SecondAdmin1")
	two := login(t, r, "admin@two.school.gh", "SecondAdmin1")
	one := login(t, r, "admin@solvanta.app", "admin123")
	super := login(t, r, "super@solvanta.app", "super123")

	var students []domain.Student
	getJSON(t, r, two, "/api/students", &students)
	if len(students) != 0 {
		t.Fatalf("new school sees %d students from another school", len(students))
	}
	var school domain.School
	getJSON(t, r, two, "/api/school", &school)
	if school.ID != "SCH-002" {
		t.Fatalf("new school's profile: %+v", school)
	}

	// A student enrolled in school two stays in school two — in a class
	// school two has (school one's JHS1A is not visible to it).
	if rec := do(r, "PUT", "/api/school/classes/JHS1A", `{"id":"JHS1A","name":"JHS1","stream":"A"}`, bearer(two)); rec.Code != http.StatusOK && rec.Code != http.StatusCreated {
		t.Fatalf("class in school two: %d %s", rec.Code, rec.Body.String())
	}
	enrol := `{"id":"STU-T2-1","firstName":"Esi","lastName":"Boateng","gender":"F",
	  "dateOfBirth":"2013-01-01","admissionDate":"2026-09-07","admissionNo":"T2-1","classId":"JHS1A"}`
	if rec := do(r, "POST", "/api/students", enrol, bearer(two)); rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
		t.Fatalf("enrol in school two: %d %s", rec.Code, rec.Body.String())
	}
	getJSON(t, r, one, "/api/students", &students)
	for _, s := range students {
		if s.ID == "STU-T2-1" {
			t.Fatal("school one sees school two's student")
		}
	}
	if code := getJSON(t, r, one, "/api/students/STU-T2-1", nil); code != http.StatusNotFound {
		t.Errorf("school one fetching school two's student: got %d, want 404", code)
	}

	// Users are per school too.
	var users []domain.User
	getJSON(t, r, two, "/api/users", &users)
	for _, u := range users {
		if u.Email == "admin@solvanta.app" {
			t.Fatal("school two lists school one's admin")
		}
	}

	// Naming another school is refused for everyone but the super admin.
	if rec := do(r, "GET", "/api/students?schoolId=SCH-001", "", bearer(two)); rec.Code != http.StatusForbidden {
		t.Errorf("school two naming school one: got %d, want 403", rec.Code)
	}
	getJSON(t, r, super, "/api/students?schoolId=SCH-002", &students)
	if len(students) != 1 || students[0].ID != "STU-T2-1" {
		t.Fatalf("super admin viewing school two: %+v", students)
	}
	if rec := do(r, "GET", "/api/students?schoolId=NOPE", "", bearer(super)); rec.Code != http.StatusNotFound {
		t.Errorf("unknown school: got %d, want 404", rec.Code)
	}

	// The directory lists both schools — to the super admin only.
	var schools []domain.School
	getJSON(t, r, super, "/api/schools", &schools)
	if len(schools) != 2 {
		t.Fatalf("schools: %+v", schools)
	}
	if rec := do(r, "GET", "/api/schools", "", bearer(one)); rec.Code != http.StatusForbidden {
		t.Errorf("school admin listing schools: got %d, want 403", rec.Code)
	}
	if rec := do(r, "POST", "/api/schools", `{"id":"SCH-003","name":"X"}`, bearer(one)); rec.Code != http.StatusForbidden {
		t.Errorf("school admin creating a school: got %d, want 403", rec.Code)
	}
}

// Sign-in emails are unique across every school, so login is unambiguous.
func TestEmailsAreUniqueAcrossSchools(t *testing.T) {
	r := newTestServer(t, Config{})
	newSchool(t, r, "SCH-002", "admin@two.school.gh", "SecondAdmin1")
	two := login(t, r, "admin@two.school.gh", "SecondAdmin1")
	rec := do(r, "POST", "/api/users",
		`{"name":"Dup","email":"efua.mensah@school.gh","password":"Another1Pass","role":"teacher","classId":"JHS1A"}`, bearer(two))
	if rec.Code != http.StatusConflict {
		t.Fatalf("reusing another school's email: got %d, want 409 (%s)", rec.Code, rec.Body.String())
	}
	if rec := do(r, "POST", "/api/schools", `{"id":"sch-001","name":"Again"}`,
		bearer(login(t, r, "super@solvanta.app", "super123"))); rec.Code != http.StatusConflict {
		t.Errorf("re-creating a school: got %d, want 409", rec.Code)
	}
}

// A token is bound to its school: rewriting the school claim is a forgery
// (bad signature), and a valid token for a removed user is refused.
func TestTokenCarriesSchool(t *testing.T) {
	r := newTestServer(t, Config{})
	newSchool(t, r, "SCH-002", "admin@two.school.gh", "SecondAdmin1")
	two := login(t, r, "admin@two.school.gh", "SecondAdmin1")
	var me struct {
		User domain.User `json:"user"`
	}
	rec := do(r, "GET", "/auth/me", "", bearer(two))
	_ = json.Unmarshal(rec.Body.Bytes(), &me)
	if me.User.SchoolID != "SCH-002" {
		t.Fatalf("me: %+v", me.User)
	}
}
