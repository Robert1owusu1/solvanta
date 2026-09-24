package httpapi

import (
	"net/http"
	"testing"
)

// TestCreateStudentValidation mirrors the client's required-field rules
// (first/last name, gender M/F, existing class) — invalid payloads get 400.
func TestCreateStudentValidation(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "efua.mensah@school.gh", "teacher123")
	auth := map[string]string{"Authorization": "Bearer " + tok}

	cases := []struct{ name, body string }{
		{"empty", `{}`},
		{"missing lastName", `{"firstName":"Kofi"}`},
		{"bad gender", `{"firstName":"Kofi","lastName":"Appiah","gender":"X","classId":"JHS2A"}`},
		{"unknown class", `{"firstName":"Kofi","lastName":"Appiah","gender":"M","classId":"JHS9Z"}`},
	}
	for _, tc := range cases {
		rec := do(r, "POST", "/api/students", tc.body, auth)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", tc.name, rec.Code)
		}
	}

	rec := do(r, "POST", "/api/students",
		`{"firstName":"Kofi","lastName":"Appiah","gender":"M","classId":"JHS2A"}`, auth)
	if rec.Code != http.StatusCreated {
		t.Fatalf("valid student: got %d, want 201 %s", rec.Code, rec.Body.String())
	}
}

// TestCreateQuestionValidation checks the question required fields and the
// objective-question invariants the app enforces (2–4 options, correctAnswer).
func TestCreateQuestionValidation(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "efua.mensah@school.gh", "teacher123")
	auth := map[string]string{"Authorization": "Bearer " + tok}

	cases := []struct{ name, body string }{
		{"unknown type", `{"type":"essayX","stem":"q","subjectId":"MATH","marks":2}`},
		{"empty stem", `{"type":"mcq","subjectId":"MATH","marks":2}`},
		{"unknown subject", `{"type":"mcq","stem":"q","subjectId":"XYZ","marks":2}`},
		{"zero marks", `{"type":"mcq","stem":"q","subjectId":"MATH","marks":0}`},
		{"difficulty out of range", `{"type":"mcq","stem":"q","subjectId":"MATH","marks":2,"difficulty":9}`},
		{"mcq with one option", `{"type":"mcq","stem":"q","subjectId":"MATH","marks":2,"options":["a"]}`},
		{"mcq without answer", `{"type":"mcq","stem":"q","subjectId":"MATH","marks":2,"options":["a","b","c","d"]}`},
		{"true/false bad answer", `{"type":"trueFalse","stem":"q","subjectId":"MATH","marks":2,"correctAnswer":"Yes"}`},
	}
	for _, tc := range cases {
		rec := do(r, "POST", "/api/questions", tc.body, auth)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", tc.name, rec.Code)
		}
	}

	rec := do(r, "POST", "/api/questions",
		`{"type":"mcq","stem":"2+2?","subjectId":"MATH","marks":2,"difficulty":1,"options":["3","4"],"correctAnswer":"4"}`, auth)
	if rec.Code != http.StatusCreated {
		t.Fatalf("valid question: got %d, want 201 %s", rec.Code, rec.Body.String())
	}
}

// TestCreateAssessmentValidation ensures title, subject, class and at least one
// question are required — the app blocks publishers with zero questions.
func TestCreateAssessmentValidation(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, "efua.mensah@school.gh", "teacher123")
	auth := map[string]string{"Authorization": "Bearer " + tok}

	cases := []struct{ name, body string }{
		{"empty title", `{"type":"classTest","subjectId":"MATH","classId":"JHS2A","questions":[{"stem":"q"}]}`},
		{"unknown subject", `{"type":"classTest","title":"T","subjectId":"XYZ","classId":"JHS2A","questions":[{"stem":"q"}]}`},
		{"no class", `{"type":"classTest","title":"T","subjectId":"MATH","questions":[{"stem":"q"}]}`},
		{"unknown class", `{"type":"classTest","title":"T","subjectId":"MATH","classId":"JHS9Z","questions":[{"stem":"q"}]}`},
		{"no questions", `{"type":"classTest","title":"T","subjectId":"MATH","classId":"JHS2A"}`},
	}
	for _, tc := range cases {
		rec := do(r, "POST", "/api/assessments", tc.body, auth)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", tc.name, rec.Code)
		}
	}

	rec := do(r, "POST", "/api/assessments",
		`{"type":"classTest","title":"Fractions","subjectId":"MATH","classId":"JHS2A","questions":[{"stem":"what is 1/2?","marks":2}]}`, auth)
	if rec.Code != http.StatusCreated {
		t.Fatalf("valid assessment: got %d, want 201 %s", rec.Code, rec.Body.String())
	}
}
