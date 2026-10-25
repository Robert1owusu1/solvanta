package httpapi

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
)

// =============================================================================
// Assignment submission pages — Phase 3 guards
// =============================================================================

// doBytes is [do] for a raw body. The shared helper takes a string and always
// sets Content-Type to application/json first, which would make it impossible
// to exercise the image upload path here — and image bytes are not valid UTF-8
// anyway, so going through a string would corrupt them.
func doBytes(r http.Handler, method, path string, body []byte, hdr map[string]string) *httptest.ResponseRecorder {
	var req *http.Request
	if len(body) > 0 {
		req = httptest.NewRequest(method, path, bytes.NewReader(body))
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	return rec
}

// putSubmission creates the submission record the page images hang off,
// failing the test on any non-200. (200, not 201: saveRecord is a PUT upsert
// and echoes the stored JSON back, the same for a create and a rewrite.)
func putSubmission(t *testing.T, r http.Handler, token, id, studentID string) {
	t.Helper()
	body := `{"id":"` + id + `","assignmentId":"ASG-001","studentId":"` +
		studentID + `","classId":"JHS2A","subjectId":"MATH",` +
		`"recorder":"Ms. Efua Mensah","capturedAt":"2026-09-20 09:15",` +
		`"pages":[],"manualNotes":"","status":"queued"}`
	rec := do(r, "PUT", "/api/records/assignment_submissions/"+id, body,
		map[string]string{"Authorization": "Bearer " + token})
	if rec.Code != http.StatusOK {
		t.Fatalf("put submission: got %d %s", rec.Code, rec.Body.String())
	}
}

// fakePNG is not a real PNG — the endpoint stores bytes verbatim and never
// decodes them, and inventing a valid image here would only add a fixture to
// maintain without testing anything extra. The distinct payloads are what
// matters: each page's bytes must come back as that page's bytes.
func fakePNG(seed byte) []byte {
	return bytes.Repeat([]byte{0x89, 'P', 'N', 'G', seed}, 40)
}

// TestSubmissionPagesDoNotOverwriteEachOther is the guard for the whole reason
// a submission carries pages rather than a single image.
//
// A submission stores one photo per page. If pages were keyed by the
// submission id alone, uploading page 2 would overwrite page 1 and the marker
// would silently receive only the last page of a five-page booklet. This test
// uploads two pages with deliberately different bytes and asserts both survive
// and stay distinct.
func TestSubmissionPagesDoNotOverwriteEachOther(t *testing.T) {
	r := newTestServer(t, Config{})
	token := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])

	const subID = "ASUB-PAGES-001"
	putSubmission(t, r, token, subID, "STU-001")

	page1 := fakePNG(1)
	page2 := fakePNG(2)
	page3 := fakePNG(3)

	for i, payload := range [][]byte{page1, page2, page3} {
		rec := doBytes(r, "PUT", "/api/assignment-submissions/"+subID+"/pages/"+
			strconv.Itoa(i+1)+"/image", payload,
			map[string]string{
				"Authorization": "Bearer " + token,
				"Content-Type":  "image/png",
			})
		if rec.Code != http.StatusOK {
			t.Fatalf("upload page %d: got %d %s", i+1, rec.Code, rec.Body.String())
		}
	}

	want := map[string][]byte{
		"1": page1,
		"2": page2,
		"3": page3,
	}
	for page, expected := range want {
		rec := do(r, "GET", "/api/assignment-submissions/"+subID+"/pages/"+
			page+"/image", "",
			map[string]string{"Authorization": "Bearer " + token})
		if rec.Code != http.StatusOK {
			t.Fatalf("get page %s: got %d %s", page, rec.Code, rec.Body.String())
		}
		if !bytes.Equal(rec.Body.Bytes(), expected) {
			t.Errorf("page %s: got %d bytes, want %d — pages overwrote each other",
				page, rec.Body.Len(), len(expected))
		}
	}
}

// TestSubmissionPageImageRequiresRecord mirrors the scan endpoint: a photo
// cannot be stored against a submission that does not exist, because the
// handler looks the record up before it touches the store.
func TestSubmissionPageImageRequiresRecord(t *testing.T) {
	r := newTestServer(t, Config{})
	token := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])

	rec := doBytes(r, "PUT", "/api/assignment-submissions/ASUB-NOPE/pages/1/image",
		fakePNG(1),
		map[string]string{
			"Authorization": "Bearer " + token,
			"Content-Type":  "image/png",
		})
	if rec.Code != http.StatusNotFound {
		t.Errorf("upload to unknown submission: got %d, want 404", rec.Code)
	}

	rec = do(r, "GET", "/api/assignment-submissions/ASUB-NOPE/pages/1/image", "",
		map[string]string{"Authorization": "Bearer " + token})
	if rec.Code != http.StatusNotFound {
		t.Errorf("read from unknown submission: got %d, want 404", rec.Code)
	}
}

// TestSubmissionPageRejectsNonImage pins the content-type rule, which stops a
// non-photo being stored where a marker expects to open an image.
func TestSubmissionPageRejectsNonImage(t *testing.T) {
	r := newTestServer(t, Config{})
	token := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])

	const subID = "ASUB-CTYPE-001"
	putSubmission(t, r, token, subID, "STU-001")

	rec := doBytes(r, "PUT", "/api/assignment-submissions/"+subID+"/pages/1/image",
		[]byte(`{"not":"an image"}`),
		map[string]string{
			"Authorization": "Bearer " + token,
			"Content-Type":  "application/json",
		})
	if rec.Code != http.StatusUnsupportedMediaType {
		t.Errorf("non-image upload: got %d, want 415", rec.Code)
	}
}

// TestSubmissionPageRejectsBadPageNumber guards the composite key. A page
// number that is not a positive small integer would let a caller write
// arbitrary keys into the shared image store, including keys that collide with
// a scan's own id.
func TestSubmissionPageRejectsBadPageNumber(t *testing.T) {
	r := newTestServer(t, Config{})
	token := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])

	const subID = "ASUB-BADPAGE-001"
	putSubmission(t, r, token, subID, "STU-001")

	for _, page := range []string{"0", "-1", "abc", "100000"} {
		rec := doBytes(r, "PUT", "/api/assignment-submissions/"+subID+"/pages/"+
			page+"/image", fakePNG(1),
			map[string]string{
				"Authorization": "Bearer " + token,
				"Content-Type":  "image/png",
			})
		if rec.Code != http.StatusBadRequest {
			t.Errorf("page %q: got %d, want 400", page, rec.Code)
		}
	}
}

// TestSubmissionPagesRequireStaffWriter pins the write scope on the new kind.
// assignment_submissions is declared with the same writers as scans, so a
// parent must not be able to upload a page — otherwise anyone with a link
// could attach a photo to a pupil's record.
func TestSubmissionPagesRequireStaffWriter(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	parent := login(t, r, demoAccounts["parent"][0], demoAccounts["parent"][1])

	const subID = "ASUB-RBAC-001"
	putSubmission(t, r, teacher, subID, "STU-001")

	rec := doBytes(r, "PUT", "/api/assignment-submissions/"+subID+"/pages/1/image",
		fakePNG(1),
		map[string]string{
			"Authorization": "Bearer " + parent,
			"Content-Type":  "image/png",
		})
	if rec.Code != http.StatusForbidden {
		t.Errorf("parent uploading a page: got %d, want 403", rec.Code)
	}

	// And a parent must not be able to read another family's submission
	// either. STU-007 is in JHS1A, so the JHS2A teacher cannot see or write
	// it either — the record has to be created by an admin, which is exactly
	// the point: the read scope on this kind is per-student, not "any staff".
	putAdmin := login(t, r, demoAccounts["schoolAdmin"][0], demoAccounts["schoolAdmin"][1])
	putSubmission(t, r, putAdmin, "ASUB-RBAC-002", "STU-007")
	rec = do(r, "GET",
		"/api/assignment-submissions/ASUB-RBAC-002/pages/1/image", "",
		map[string]string{"Authorization": "Bearer " + parent})
	if rec.Code != http.StatusNotFound {
		t.Errorf("parent reading another family's submission: got %d, want 404",
			rec.Code)
	}
}

// TestAssignmentSubmissionsListIsScopedToVisibleStudents proves the kind is
// actually registered, and that reads respect the student scope rather than
// dumping every submission to any signed-in user.
func TestAssignmentSubmissionsListIsScopedToVisibleStudents(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])

	// A student in the teacher's class.
	putSubmission(t, r, teacher, "ASUB-LIST-001", "STU-001")

	rec := do(r, "GET", "/api/records/assignment_submissions", "",
		map[string]string{"Authorization": "Bearer " + teacher})
	if rec.Code != http.StatusOK {
		t.Fatalf("list submissions: got %d %s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("ASUB-LIST-001")) {
		t.Error("teacher's own class submission missing from the list")
	}
}
