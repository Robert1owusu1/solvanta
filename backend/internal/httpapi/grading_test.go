package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/security"
)

// fortySixty is a school that grades JHS 40/60 on the 1–9 scale and its
// primary classes 50/50 with letters.
const fortySixty = `{"schemes":[
 {"id":"jhs","name":"JHS","isDefault":true,"classNames":[],"classWeight":40,"examWeight":60,
  "bands":[{"min":0,"grade":"9","remark":"Lowest"},{"min":80,"grade":"1","remark":"Highest"}],
  "showAggregate":true,"coreSubjects":["ENG","MATH"],"bestOthers":2,
  "promoteAt":50,"repeatBelow":40,"interventionBelow":45},
 {"id":"pri","name":"Primary","classNames":[" b1 ","B2"],"classWeight":50,"examWeight":50,
  "bands":[{"min":70,"grade":"A","remark":"Excellent"},{"min":0,"grade":"F","remark":"Fail"}],
  "showAggregate":false}]}`

func TestGradingDefaultsThenAdminSaves(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	admin := login(t, r, "admin@solvanta.app", "admin123")
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")

	var g domain.GradingConfig
	if code := getJSON(t, r, teacher, "/api/school/grading", &g); code != http.StatusOK {
		t.Fatalf("read default: %d", code)
	}
	if len(g.Schemes) != 1 || g.Schemes[0].ClassWeight != 30 || g.Schemes[0].ExamWeight != 70 {
		t.Fatalf("default should be GES 30/70, got %+v", g.Schemes)
	}

	rec := do(r, "PUT", "/api/school/grading", fortySixty, bearer(admin))
	if rec.Code != http.StatusOK {
		t.Fatalf("admin save: %d %s", rec.Code, rec.Body.String())
	}
	getJSON(t, r, teacher, "/api/school/grading", &g)
	jhs, pri := g.Schemes[0], g.Schemes[1]
	if jhs.ClassWeight != 40 || jhs.ExamWeight != 60 {
		t.Fatalf("JHS split: %+v", jhs)
	}
	if jhs.Bands[0].Grade != "1" || jhs.Bands[1].Min != 0 {
		t.Fatalf("bands not sorted highest first: %+v", jhs.Bands)
	}
	if strings.Join(pri.ClassNames, ",") != "B1,B2" {
		t.Fatalf("class names not normalised: %v", pri.ClassNames)
	}
	if jhs.PromoteAt == nil || *jhs.PromoteAt != 50 || *jhs.RepeatBelow != 40 || *jhs.InterventionBelow != 45 {
		t.Fatalf("year thresholds not kept: %+v", jhs)
	}
	if pri.PromoteAt != nil {
		t.Fatalf("unset threshold came back set: %v", *pri.PromoteAt)
	}
	if g.SchoolID != "SCH-001" || g.UpdatedBy == "" {
		t.Fatalf("server must stamp school and editor: %+v", g)
	}
}

func TestGradingOnlyTheSchoolAdminMaySave(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	for _, acct := range [][2]string{
		{"head@school.gh", "head123"},
		{"efua.mensah@school.gh", "teacher123"},
		{"ama.owusu@school.gh", "parent123"},
		{"kojo.owusu@school.gh", "student123"},
	} {
		tok := login(t, r, acct[0], acct[1])
		if rec := do(r, "PUT", "/api/school/grading", fortySixty, bearer(tok)); rec.Code != http.StatusForbidden {
			t.Errorf("%s saving grading: got %d, want 403", acct[0], rec.Code)
		}
	}
}

func TestGradingRejectsBrokenSchemes(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	admin := login(t, r, "admin@solvanta.app", "admin123")
	for name, body := range map[string]string{
		"split not 100":                strings.Replace(fortySixty, `"examWeight":60`, `"examWeight":50`, 1),
		"class in two schemes":         strings.Replace(fortySixty, `"classNames":[]`, `"classNames":["B1"]`, 1),
		"no default":                   strings.Replace(fortySixty, `"isDefault":true`, `"isDefault":false`, 1),
		"lowest band not 0":            strings.Replace(fortySixty, `{"min":0,"grade":"F"`, `{"min":10,"grade":"F"`, 1),
		"letter grades with aggregate": strings.Replace(fortySixty, `"showAggregate":false`, `"showAggregate":true`, 1),
		"duplicate band":               strings.Replace(fortySixty, `{"min":80,"grade":"1"`, `{"min":0,"grade":"1"`, 1),
		"empty grade":                  strings.Replace(fortySixty, `"grade":"A"`, `"grade":" "`, 1),
		"no schemes":                   `{"schemes":[]}`,
		"repeat above promote":         strings.Replace(fortySixty, `"interventionBelow":45`, `"interventionBelow":45,"promoteAt":50,"repeatBelow":60`, 1),
		"threshold over 100":           strings.Replace(fortySixty, `"interventionBelow":45`, `"interventionBelow":120`, 1),
	} {
		if rec := do(r, "PUT", "/api/school/grading", body, bearer(admin)); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", name, rec.Code)
		}
	}
}

// One school's admin can neither change nor see another school's grading,
// and a saved config never leaks across schools.
func TestGradingIsPerSchool(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	hash, err := security.HashPassword("OtherAdmin1")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SaveUser(domain.User{
		ID: "USR-ADM-002", Name: "Other Admin", Email: "admin@other.school.gh",
		Password: hash, Role: domain.RoleSchoolAdmin, SchoolID: "SCH-002",
	}); err != nil {
		t.Fatal(err)
	}
	other := login(t, r, "admin@other.school.gh", "OtherAdmin1")
	ours := login(t, r, "admin@solvanta.app", "admin123")

	if rec := do(r, "PUT", "/api/school/grading", fortySixty, bearer(other)); rec.Code != http.StatusOK {
		t.Fatalf("other school's admin saving its own: %d %s", rec.Code, rec.Body.String())
	}
	var g domain.GradingConfig
	getJSON(t, r, ours, "/api/school/grading", &g)
	if g.SchoolID != "SCH-001" || g.Schemes[0].ClassWeight != 30 {
		t.Fatalf("SCH-002's save changed SCH-001: %+v", g)
	}
	if rec := do(r, "PUT", "/api/school/grading?schoolId=SCH-001", fortySixty, bearer(other)); rec.Code != http.StatusForbidden {
		t.Errorf("writing another school's grading: got %d, want 403", rec.Code)
	}
	if rec := do(r, "GET", "/api/school/grading?schoolId=SCH-001", "", bearer(other)); rec.Code != http.StatusForbidden {
		t.Errorf("reading another school's grading: got %d, want 403", rec.Code)
	}
	// The body cannot redirect a save to another school either.
	sneaky := strings.Replace(fortySixty, `{"schemes"`, `{"schoolId":"SCH-001","schemes"`, 1)
	rec := do(r, "PUT", "/api/school/grading", sneaky, bearer(other))
	_ = json.Unmarshal(rec.Body.Bytes(), &g)
	if g.SchoolID != "SCH-002" {
		t.Errorf("body schoolId was trusted: saved to %q", g.SchoolID)
	}
}

// Moving to a new term closes the old one on the server, with the grading it
// was awarded under; a later grading change doesn't rewrite it, correcting
// the current term's dates closes nothing, and every role can read the list.
func TestFinishedTermsKeepTheirGrading(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	admin := login(t, r, "admin@solvanta.app", "admin123")
	parent := login(t, r, "ama.owusu@school.gh", "parent123")

	if rec := do(r, "PUT", "/api/school/grading", fortySixty, bearer(admin)); rec.Code != http.StatusOK {
		t.Fatalf("save grading: %d", rec.Code)
	}
	// Seeded term: Term 1, 2026-09-07 → 2026-12-18. Fix its end date first.
	if rec := do(r, "PUT", "/api/school/term", `{"end":"2026-12-19"}`, bearer(admin)); rec.Code != http.StatusOK {
		t.Fatalf("edit term: %d", rec.Code)
	}
	var terms []domain.FinishedTerm
	getJSON(t, r, admin, "/api/school/terms", &terms)
	if len(terms) != 0 {
		t.Fatalf("editing dates closed a term: %+v", terms)
	}
	if rec := do(r, "PUT", "/api/school/term",
		`{"year":"2026/2027","name":"Term 2","start":"2027-01-11","end":"2027-04-09"}`, bearer(admin)); rec.Code != http.StatusOK {
		t.Fatalf("new term: %d", rec.Code)
	}
	// The school changes its grading afterwards…
	fifty := strings.ReplaceAll(fortySixty, `"classWeight":40,"examWeight":60`, `"classWeight":50,"examWeight":50`)
	if rec := do(r, "PUT", "/api/school/grading", fifty, bearer(admin)); rec.Code != http.StatusOK {
		t.Fatalf("change grading: %d", rec.Code)
	}
	// …but Term 1 keeps the 40/60 it was awarded under.
	if code := getJSON(t, r, parent, "/api/school/terms", &terms); code != http.StatusOK {
		t.Fatalf("parent reading terms: %d", code)
	}
	if len(terms) != 1 || terms[0].Name != "Term 1" || terms[0].End != "2026-12-19" {
		t.Fatalf("finished terms: %+v", terms)
	}
	if w := terms[0].Grading.Schemes[0].ClassWeight; w != 40 {
		t.Fatalf("Term 1 grading: class weight %v, want 40", w)
	}
}

// End-of-year decisions are written by school leaders only and read back by
// the student's own parent, never another family.
func TestPromotionRecordsScope(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	head := login(t, r, "head@school.gh", "head123")
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	parent := login(t, r, "ama.owusu@school.gh", "parent123")
	body := `{"id":"2026-2027-STU-001","studentId":"STU-001","classId":"JHS2A","year":"2026/2027","toClassId":"JHS3A","outcome":"promoted","average":71.5}`
	if rec := do(r, "PUT", "/api/records/promotions/2026-2027-STU-001", body, bearer(teacher)); rec.Code != http.StatusForbidden {
		t.Errorf("teacher writing a promotion: got %d, want 403", rec.Code)
	}
	if rec := do(r, "PUT", "/api/records/promotions/2026-2027-STU-001", body, bearer(head)); rec.Code != http.StatusOK {
		t.Fatalf("headteacher writing a promotion: %d %s", rec.Code, rec.Body.String())
	}
	var rows []map[string]any
	getJSON(t, r, parent, "/api/records/promotions", &rows)
	if len(rows) != 1 || rows[0]["toClassId"] != "JHS3A" {
		t.Fatalf("parent of STU-001 should see the decision: %v", rows)
	}
	other := strings.ReplaceAll(body, "STU-001", "STU-003")
	do(r, "PUT", "/api/records/promotions/2026-2027-STU-003", other, bearer(head))
	getJSON(t, r, parent, "/api/records/promotions", &rows)
	for _, row := range rows {
		if row["studentId"] == "STU-003" {
			t.Fatal("parent sees another family's promotion")
		}
	}
}
