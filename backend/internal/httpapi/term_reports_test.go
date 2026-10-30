package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

const reportPath = "/api/records/term_reports/2026-2027-Term-1-STU-001"

func reportBody(status, teacherRemark, headRemark string) string {
	b, _ := json.Marshal(map[string]any{
		"id": "2026-2027-Term-1-STU-001", "studentId": "STU-001", "classId": "JHS2A",
		"year": "2026/2027", "term": "Term 1", "status": status,
		"teacherRemark": teacherRemark, "conduct": "Very good",
		"headRemark": headRemark,
		"snapshot":   map[string]any{"studentName": "Kojo Owusu", "overall": 71.5},
		"approvedBy": "someone else",
	})
	return string(b)
}

func listReports(t *testing.T, r http.Handler, tok string) []map[string]any {
	t.Helper()
	var rows []map[string]any
	getJSON(t, r, tok, "/api/records/term_reports", &rows)
	return rows
}

func TestTermReportsTwoHandsAndApproval(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	parent := login(t, r, "ama.owusu@school.gh", "parent123")

	// The class teacher writes a draft; server stamps nothing of theirs.
	if rec := do(r, "PUT", reportPath, reportBody("draft", "Works hard.", ""), bearer(teacher)); rec.Code != http.StatusOK {
		t.Fatalf("teacher draft: %d %s", rec.Code, rec.Body.String())
	}
	if rows := listReports(t, r, parent); len(rows) != 0 {
		t.Fatalf("parent sees a draft: %v", rows)
	}
	// …and may not approve, or write the headteacher's remark.
	if rec := do(r, "PUT", reportPath, reportBody("approved", "Works hard.", ""), bearer(teacher)); rec.Code != http.StatusForbidden {
		t.Errorf("teacher approving: got %d, want 403", rec.Code)
	}
	if rec := do(r, "PUT", reportPath, reportBody("draft", "Works hard.", "Well done."), bearer(teacher)); rec.Code != http.StatusForbidden {
		t.Errorf("teacher writing the head's remark: got %d, want 403", rec.Code)
	}

	// The headteacher adds a remark and approves: the server stamps who/when.
	rec := do(r, "PUT", reportPath, reportBody("approved", "Works hard.", "Well done."), bearer(head))
	if rec.Code != http.StatusOK {
		t.Fatalf("head approving: %d %s", rec.Code, rec.Body.String())
	}
	rows := listReports(t, r, parent)
	if len(rows) != 1 || rows[0]["approvedBy"] == "someone else" || rows[0]["approvedAt"] == nil {
		t.Fatalf("parent's approved report: %v", rows)
	}
	if !strings.Contains(rows[0]["approvedBy"].(string), "") || rows[0]["snapshot"] == nil {
		t.Fatalf("snapshot missing: %v", rows[0])
	}

	// Approved means frozen: the teacher can't touch it, the head must reopen.
	if rec := do(r, "PUT", reportPath, reportBody("draft", "Changed.", "Well done."), bearer(teacher)); rec.Code != http.StatusConflict {
		t.Errorf("teacher editing an approved report: got %d, want 409", rec.Code)
	}
	if rec := do(r, "PUT", reportPath, reportBody("approved", "Changed.", "Well done."), bearer(head)); rec.Code != http.StatusConflict {
		t.Errorf("head editing without reopening: got %d, want 409", rec.Code)
	}
	if rec := do(r, "DELETE", reportPath, "", bearer(head)); rec.Code != http.StatusConflict {
		t.Errorf("deleting an approved report: got %d, want 409", rec.Code)
	}
	// Re-sending the same approval (an outbox replay) is fine and keeps the stamp.
	if rec := do(r, "PUT", reportPath, reportBody("approved", "Works hard.", "Well done."), bearer(head)); rec.Code != http.StatusOK {
		t.Errorf("replayed approval: got %d, want 200", rec.Code)
	}
	if again := listReports(t, r, parent); again[0]["approvedAt"] != rows[0]["approvedAt"] {
		t.Errorf("replay re-stamped the approval: %v vs %v", again[0]["approvedAt"], rows[0]["approvedAt"])
	}

	// Reopening drops the frozen copy and hides it from the family again.
	if rec := do(r, "PUT", reportPath, reportBody("draft", "Works hard.", "Well done."), bearer(head)); rec.Code != http.StatusOK {
		t.Fatalf("head reopening: %d", rec.Code)
	}
	if rows := listReports(t, r, parent); len(rows) != 0 {
		t.Fatalf("reopened report still visible to the parent")
	}
	staff := listReports(t, r, head)
	if len(staff) != 1 || staff[0]["snapshot"] != nil || staff[0]["approvedBy"] != nil {
		t.Fatalf("reopened report kept its approval: %v", staff)
	}
}

func TestTermReportsOnlyOwnClassForTeachers(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123") // JHS2A
	other := strings.NewReplacer("STU-001", "STU-007", "JHS2A", "JHS1A").Replace(reportBody("draft", "x", ""))
	if rec := do(r, "PUT", "/api/records/term_reports/2026-2027-Term-1-STU-007", other, bearer(teacher)); rec.Code != http.StatusForbidden {
		t.Errorf("teacher writing another class's report: got %d, want 403", rec.Code)
	}
}

func TestApprovalNotifiesTheFamily(t *testing.T) {
	r := newTestServer(t, Config{})
	head := login(t, r, "head@school.gh", "head123")
	parent := login(t, r, "ama.owusu@school.gh", "parent123")
	do(r, "PUT", reportPath, reportBody("approved", "Good.", "Good."), bearer(head))
	var notes []map[string]any
	getJSON(t, r, parent, "/api/notifications", &notes)
	for _, n := range notes {
		if n["kind"] == "reportCard" {
			return
		}
	}
	t.Fatalf("no report-card notice for the parent: %v", notes)
}

func TestSubjectRemarksAreBounded(t *testing.T) {
	r := newTestServer(t, Config{})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	long := strings.Repeat("x", 81)
	body := strings.Replace(reportBody("draft", "ok", ""), `"status"`,
		`"subjectRemarks":{"ENG":"`+long+`"},"status"`, 1)
	if rec := do(r, "PUT", reportPath, body, bearer(teacher)); rec.Code != http.StatusBadRequest {
		t.Fatalf("an 81-character subject remark: got %d, want 400", rec.Code)
	}
	ok := strings.Replace(reportBody("draft", "ok", ""), `"status"`,
		`"subjectRemarks":{"ENG":"Reads widely"},"status"`, 1)
	if rec := do(r, "PUT", reportPath, ok, bearer(teacher)); rec.Code != http.StatusOK {
		t.Fatalf("a subject remark from the class teacher: %d %s", rec.Code, rec.Body.String())
	}
}
