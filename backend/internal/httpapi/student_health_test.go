package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"

	"solvanta/backend/internal/domain"
)

func TestStudentHealthRoundTrips(t *testing.T) {
	r, _ := newTestServerWithStore(t, Config{})
	admin := bearer(login(t, r, "admin@solvanta.app", "admin123"))

	body := `{"firstName":"Kofi","lastName":"Mensah","gender":"M","classId":"JHS2A",
		"health":{"bloodGroup":"O+","allergies":["peanuts","penicillin"],
		"conditions":["asthma"],"notes":"Carries an inhaler"}}`
	rec := do(r, "POST", "/api/students", body, admin)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body.String())
	}
	var created domain.Student
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if created.Health == nil || created.Health.BloodGroup != "O+" ||
		len(created.Health.Allergies) != 2 || created.Health.Notes != "Carries an inhaler" {
		t.Fatalf("health not stored on create: %+v", created.Health)
	}

	// Read it back through the detail endpoint.
	rec = do(r, "GET", "/api/students/"+created.ID, "", admin)
	var detail struct {
		Student domain.Student `json:"student"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &detail)
	if detail.Student.Health == nil || detail.Student.Health.Conditions[0] != "asthma" {
		t.Errorf("health not returned on read: %+v", detail.Student.Health)
	}

	// A student (or parent) view must still carry their own health info.
	student := bearer(login(t, r, "kojo.owusu@school.gh", "student123"))
	// STU-001 (Kojo) has no health record; add one as admin then read as the pupil.
	do(r, "PATCH", "/api/students/STU-001",
		`{"health":{"bloodGroup":"A-","allergies":["shellfish"]}}`, admin)
	rec = do(r, "GET", "/api/students/STU-001", "", student)
	_ = json.Unmarshal(rec.Body.Bytes(), &detail)
	if detail.Student.Health == nil || detail.Student.Health.BloodGroup != "A-" {
		t.Errorf("pupil cannot see own health: %+v", detail.Student.Health)
	}
}
