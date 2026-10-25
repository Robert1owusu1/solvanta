package httpapi

import (
	"net/http"
	"strings"
	"testing"
)

// The OCR record kind carries a photographed page and the teacher's
// confirmation of what it says. These tests pin how narrowly it is visible —
// the kind was added in this phase, so the boundary around it has to be
// asserted rather than assumed.

// TestOcrJobsAreStaffOnly: only staff may write, and nobody reads without
// signing in. The writers list is what stops a pupil posting readings about
// work that was never theirs.
func TestOcrJobsAreStaffOnly(t *testing.T) {
	r := newTestServer(t, Config{})

	if rec := do(r, "GET", "/api/records/ocr_jobs", ``, nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("unauthenticated read = %d, want 401", rec.Code)
	}
	if rec := do(r, "PUT", "/api/records/ocr_jobs/OCR-A", `{"id":"OCR-A"}`, nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("unauthenticated write = %d, want 401", rec.Code)
	}

	for _, role := range []string{"parent", "student"} {
		tok := login(t, r, demoAccounts[role][0], demoAccounts[role][1])
		rec := do(r, "PUT", "/api/records/ocr_jobs/OCR-"+role,
			`{"id":"OCR-`+role+`","status":"read"}`, bearer(tok))
		if rec.Code != http.StatusForbidden {
			t.Errorf("%s write = %d, want 403", role, rec.Code)
		}
	}

	for _, role := range []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"} {
		tok := login(t, r, demoAccounts[role][0], demoAccounts[role][1])
		rec := do(r, "PUT", "/api/records/ocr_jobs/OCR-"+role,
			`{"id":"OCR-`+role+`","status":"read"}`, bearer(tok))
		if rec.Code != http.StatusOK {
			t.Errorf("%s write = %d %s, want 200", role, rec.Code, rec.Body.String())
		}
	}
}

// TestOcrJobsAreScopedToTheirOwner: a reading belongs to the teacher who made
// it. Another member of staff — a headteacher, who outranks them — must not
// see it, because scopeOwner compares against the row's stored owner and not
// against job seniority.
func TestOcrJobsAreScopedToTheirOwner(t *testing.T) {
	r := newTestServer(t, Config{})
	creator := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	other := login(t, r, demoAccounts["headteacher"][0], demoAccounts["headteacher"][1])

	rec := do(r, "PUT", "/api/records/ocr_jobs/OCR-OWNER-1",
		`{"id":"OCR-OWNER-1","subjectId":"MATH","topic":"Algebra",`+
			`"status":"confirmed","text":"x = 3","reviewedText":"x = 3"}`,
		bearer(creator))
	if rec.Code != http.StatusOK {
		t.Fatalf("owner write = %d %s", rec.Code, rec.Body.String())
	}

	own := do(r, "GET", "/api/records/ocr_jobs", ``, bearer(creator))
	if !strings.Contains(own.Body.String(), "OCR-OWNER-1") {
		t.Errorf("the teacher who confirmed it cannot see it: %s", own.Body.String())
	}

	someoneElses := do(r, "GET", "/api/records/ocr_jobs", ``, bearer(other))
	if strings.Contains(someoneElses.Body.String(), "OCR-OWNER-1") {
		t.Errorf("an OCR job was visible to a teacher who did not create it: %s",
			someoneElses.Body.String())
	}
}

// TestOcrJobOwnerIdCannotBeSpoofed: the client's JSON is stored verbatim as
// the record's Data, so an ownerId inside it survives the round trip. It must
// decide nothing — the owner is stamped from the session on the way in, or a
// pupil could post a row claiming to belong to someone else and a teacher
// could claim a colleague's.
func TestOcrJobOwnerIdCannotBeSpoofed(t *testing.T) {
	r := newTestServer(t, Config{})
	creator := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	other := login(t, r, demoAccounts["headteacher"][0], demoAccounts["headteacher"][1])

	// Claim, in the body, that this row belongs to somebody else entirely.
	rec := do(r, "PUT", "/api/records/ocr_jobs/OCR-SPOOF-1",
		`{"id":"OCR-SPOOF-1","ownerId":"USR-DOES-NOT-EXIST","status":"read","text":"reading"}`,
		bearer(creator))
	if rec.Code != http.StatusOK {
		t.Fatalf("write = %d %s", rec.Code, rec.Body.String())
	}

	// The spoofed field did not move the row to anyone else…
	if list := do(r, "GET", "/api/records/ocr_jobs", ``, bearer(other)); strings.Contains(list.Body.String(), "OCR-SPOOF-1") {
		t.Error("a body-supplied ownerId granted another user access")
	}
	// …and the person who actually wrote it still has it, because the server
	// stamped the owner from their session instead.
	if list := do(r, "GET", "/api/records/ocr_jobs", ``, bearer(creator)); !strings.Contains(list.Body.String(), "OCR-SPOOF-1") {
		t.Error("the session owner lost their own record to a field in their own body")
	}
}

// TestOcrJobCannotBeOverwrittenByAnotherTeacher: writing a row you do not own
// is refused against BOTH the incoming row and the stored one, so a second
// teacher cannot amend a confirmation somebody else already made. A
// confirmation that anyone could edit later is not a confirmation.
func TestOcrJobCannotBeOverwrittenByAnotherTeacher(t *testing.T) {
	r := newTestServer(t, Config{})
	creator := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	other := login(t, r, demoAccounts["headteacher"][0], demoAccounts["headteacher"][1])

	rec := do(r, "PUT", "/api/records/ocr_jobs/OCR-LOCK-1",
		`{"id":"OCR-LOCK-1","status":"confirmed","text":"3"}`, bearer(creator))
	if rec.Code != http.StatusOK {
		t.Fatalf("first write = %d %s", rec.Code, rec.Body.String())
	}

	rec = do(r, "PUT", "/api/records/ocr_jobs/OCR-LOCK-1",
		`{"id":"OCR-LOCK-1","status":"confirmed","text":"tampered"}`, bearer(other))
	if rec.Code != http.StatusForbidden {
		t.Errorf("overwrite by another teacher = %d, want 403", rec.Code)
	}

	// And the original is untouched.
	own := do(r, "GET", "/api/records/ocr_jobs", ``, bearer(creator))
	if !strings.Contains(own.Body.String(), `"text":"3"`) ||
		strings.Contains(own.Body.String(), "tampered") {
		t.Errorf("the stored confirmation was altered: %s", own.Body.String())
	}
}

// TestOcrJobRecordKindIsKnownToTheRouter: an unregistered kind 404s rather
// than silently accepting writes for a collection nobody reads back.
func TestOcrJobRecordKindIsKnownToTheRouter(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])

	if rec := do(r, "GET", "/api/records/not_a_collection", ``, bearer(tok)); rec.Code != http.StatusNotFound {
		t.Errorf("unknown kind = %d, want 404", rec.Code)
	}
	if rec := do(r, "GET", "/api/records/ocr_jobs", ``, bearer(tok)); rec.Code != http.StatusOK {
		t.Errorf("ocr_jobs = %d, want 200 — the kind must be registered", rec.Code)
	}
}
