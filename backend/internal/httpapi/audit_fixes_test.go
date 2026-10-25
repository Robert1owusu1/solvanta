package httpapi

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// =============================================================================
// Regression guards for the pre-Phase-5 audit
// =============================================================================

// TestSchemeMarksAreValidatedBeforeSaving: every mark must fit NUMERIC(6,2)
// and stay inside its question's total. 3.333 used to pass the handler's
// tolerance and then fail PostgreSQL's exact breakdown check as a 500.
func TestSchemeMarksAreValidatedBeforeSaving(t *testing.T) {
	question := func(total, step, answer, misc string) string {
		return fmt.Sprintf(`[{"questionNumber":1,"totalMarks":%s,
			"markBreakdown":[%s],
			"acceptedAnswers":[{"answerText":"x","normalizedForm":"x","marksAwarded":%s,"isPrimary":true}],
			"misconceptions":[{"wrongAnswerPattern":"y","likelyCause":"z","marksAwarded":%s}]}]`,
			total, step, answer, misc)
	}
	cases := []struct {
		name, questions string
		want            int
	}{
		{"valid two-decimal marks", question("10", `{"marks":3.33},{"marks":3.33},{"marks":3.34}`, "10", "1.5"), http.StatusCreated},
		{"three decimal places", question("10", `{"marks":3.333},{"marks":3.333},{"marks":3.334}`, "10", "0"), http.StatusBadRequest},
		{"breakdown short by a cent", question("10", `{"marks":3.33},{"marks":3.33},{"marks":3.33}`, "10", "0"), http.StatusBadRequest},
		{"negative step", question("4", `{"marks":6},{"marks":-2}`, "4", "0"), http.StatusBadRequest},
		{"answer above total", question("4", `{"marks":4}`, "5", "0"), http.StatusBadRequest},
		{"misconception above total", question("4", `{"marks":4}`, "4", "9"), http.StatusBadRequest},
		{"total too large for the column", question("10000", `{"marks":10000}`, "1", "0"), http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := newTestServer(t, Config{})
			tok := login(t, r, "head@school.gh", "head123")
			rec := do(r, "POST", "/api/assessments/ASSMT-MAT-HALF/marking-scheme",
				`{"assessmentId":"ASSMT-MAT-HALF","questions":`+tc.questions+`}`, bearer(tok))
			if rec.Code != tc.want {
				t.Fatalf("got %d, want %d: %s", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}

// TestGenerateAcceptsARealSizedPhoto: the app's OCR captures encode to
// roughly 1.75–3.3 MB, past the 1 MiB default body cap, which turned every
// real photo into a 413. The generate route has its own larger cap.
func TestGenerateAcceptsARealSizedPhoto(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"ENG","topic":"Essay","type":"mcq","count":1}`)

	photo := base64.StdEncoding.EncodeToString(make([]byte, 2<<20)) // ~2.7 MB encoded
	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate",
		`{"imageBase64":"`+photo+`","contentType":"image/jpeg"}`, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("generate with a %d-byte body: got %d %.200s", len(photo), rec.Code, rec.Body.String())
	}

	// The larger cap is for this route only; everything else keeps 1 MiB.
	big := `{"id":"L-1","title":"` + strings.Repeat("x", 2<<20) + `"}`
	if rec := do(r, "PUT", "/api/records/lessons/L-1", big, bearer(tok)); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("2 MB record body: got %d, want 413", rec.Code)
	}
}

// TestRecordIDsMayNotContainHash: '#' separates a submission id from its page
// number in the photo store, so a record named "<submission>#<page>" would
// alias that page's photo through its own /image route.
func TestRecordIDsMayNotContainHash(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	rec := do(r, "PUT", "/api/records/scans/ASUB-1%231",
		`{"id":"ASUB-1#1","studentId":"STU-001"}`, bearer(tok))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("record id with '#': got %d, want 400 (%s)", rec.Code, rec.Body.String())
	}
}
