package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// getInvoices fetches /api/invoices for a session and fails the test on
// anything but a 200, so a scope assertion never accidentally tests a 401.
func getInvoices(t *testing.T, r *gin.Engine, hdr map[string]string, query string) []domain.Invoice {
	t.Helper()
	rec := do(r, http.MethodGet, "/api/invoices"+query, "", hdr)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/invoices%s: got %d %s", query, rec.Code, rec.Body.String())
	}
	var out []domain.Invoice
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode GET /api/invoices%s: %v — body %s", query, err, rec.Body.String())
	}
	return out
}

// TestInvoiceReadsScopePerStudent is the point of putting fees behind the API at
// all: readable from any device must not become readable by anyone. Staff see
// every bill, a parent their own child's, a student their own — and asking for
// somebody else's student answers with an empty list, not an error that names a
// student the caller was never entitled to learn exists.
func TestInvoiceReadsScopePerStudent(t *testing.T) {
	r, _ := newFeesServer(t)
	bearer := func(email, pass string) map[string]string {
		return map[string]string{"Authorization": "Bearer " + login(t, r, email, pass)}
	}
	staff := bearer("admin@solvanta.app", "admin123")
	parent := bearer("ama.owusu@school.gh", "parent123")
	otherParent := bearer("akua.boaduwaa@school.gh", "parent123")
	pupil := bearer("kojo.owusu@school.gh", "student123")

	all := getInvoices(t, r, staff, "")
	if len(all) != 8 {
		t.Fatalf("staff sees %d invoices, want the 8 seeded — one per student", len(all))
	}

	for name, hdr := range map[string]map[string]string{
		"parent":  parent,
		"student": pupil,
	} {
		mine := getInvoices(t, r, hdr, "")
		if len(mine) != 1 || mine[0].StudentID != "STU-001" {
			t.Fatalf("%s sees %+v, want exactly their own child's invoice", name, mine)
		}
	}

	// A student outside the caller's scope is filtered out, not refused: the
	// list is "here is what you may see".
	if asked := getInvoices(t, r, parent, "?studentId=STU-002"); len(asked) != 0 {
		t.Fatalf("parent was served another family's invoice: %+v", asked)
	}
	// The same filter does work for someone entitled to it.
	if filtered := getInvoices(t, r, staff, "?studentId=STU-002"); len(filtered) != 1 ||
		filtered[0].StudentID != "STU-002" {
		t.Fatalf("staff ?studentId=STU-002 gave %+v, want that one invoice", filtered)
	}

	// Detail reads apply the same rule, and here an explicit 403 is right:
	// the caller asked for one specific bill by id and is told no. (Asked for
	// her OWN child's id this parent would be served 200 — that is asserted
	// through the list above.)
	rec := do(r, http.MethodGet, "/api/invoices/INV-2026T1-STU-001", "", otherParent)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("another family's invoice detail: got %d %s, want 403", rec.Code, rec.Body.String())
	}

	// And an anonymous session reaches none of it.
	if anon := do(r, http.MethodGet, "/api/invoices", "", nil); anon.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated invoices read: got %d, want 401", anon.Code)
	}
}

// TestInvoiceAmountsDeriveFromPayments pins the design decision the schema
// encodes: amountPaid and status are NOT stored, they are summed from the
// payments table on every read. A stored copy would be right only until the
// next payment — here a payment posted after the fact must show up on the
// invoice immediately, which is the whole reason two devices can trust one bill.
//
// Only date-independent facts are asserted (sums, and statuses that hold on any
// day from the seed date onward); the partial/due branches depend on today's
// date and are pinned separately in domain.TestInvoiceResolveStatus.
func TestInvoiceAmountsDeriveFromPayments(t *testing.T) {
	r, _ := newFeesServer(t)
	staff := map[string]string{"Authorization": "Bearer " + login(t, r, "admin@solvanta.app", "admin123")}

	invoices := getInvoices(t, r, staff, "")
	byStudent := map[string]domain.Invoice{}
	for _, inv := range invoices {
		byStudent[inv.StudentID] = inv
	}

	// Seed pattern 0 is settled in full: the sum of that student's payments is
	// the whole bill, so nothing is owed and the status is paid — on any day.
	settled := byStudent["STU-001"]
	if settled.AmountPaid != settled.Total() || settled.AmountPaid == 0 {
		t.Fatalf("settled invoice shows amountPaid %d of total %d, want it paid in full",
			settled.AmountPaid, settled.Total())
	}
	if settled.Status != domain.InvoiceStatusPaid {
		t.Fatalf("settled invoice status = %q, want %q", settled.Status, domain.InvoiceStatusPaid)
	}

	// Seed pattern 1 is part-paid: 60% of the bill has arrived.
	partial := byStudent["STU-002"]
	if want := partial.Total() * 60 / 100; partial.AmountPaid != want {
		t.Fatalf("part-paid invoice shows %d, want %d (60%% of %d)",
			partial.AmountPaid, want, partial.Total())
	}
	if partial.Balance() <= 0 {
		t.Fatalf("part-paid invoice claims no balance: %+v", partial)
	}

	// Seed pattern 2 has never been paid and its due date was mid-September:
	// overdue whatever today is, from the seed date onward.
	unpaid := byStudent["STU-003"]
	if unpaid.AmountPaid != 0 {
		t.Fatalf("unpaid invoice shows %d paid, want 0", unpaid.AmountPaid)
	}
	if unpaid.Status != domain.InvoiceStatusOverdue {
		t.Fatalf("unpaid past-due invoice status = %q, want %q", unpaid.Status, domain.InvoiceStatusOverdue)
	}

	// The live proof of derivation: a payment recorded NOW must move a bill
	// that was written with no amount_paid column to move.
	before := byStudent["STU-004"]
	if before.AmountPaid != 0 {
		t.Fatalf("invoice %s starts at %d paid, want 0 so the probe is meaningful",
			before.ID, before.AmountPaid)
	}
	rec := do(r, http.MethodPost, "/api/payments",
		`{"id":"PAY-DERIVED-PROBE","invoiceId":"`+before.ID+`","studentId":"STU-004",`+
			`"amount":100,"method":"cash","paidAt":"2026-10-01 09:41","recordedBy":"Bursar"}`,
		staff)
	if rec.Code != http.StatusCreated {
		t.Fatalf("probe payment: got %d %s", rec.Code, rec.Body.String())
	}

	after := getInvoices(t, r, staff, "?studentId=STU-004")
	if len(after) != 1 || after[0].ID != before.ID {
		t.Fatalf("probe invoice not returned: %+v", after)
	}
	if after[0].AmountPaid != before.AmountPaid+100 {
		t.Fatalf("invoice reads %d paid after a 100 GHS payment, want %d — "+
			"the amount is not being derived from the payments table",
			after[0].AmountPaid, before.AmountPaid+100)
	}
	// Balance is what the money says, not what was written at creation.
	if after[0].Balance() != after[0].Total()-before.AmountPaid-100 {
		t.Fatalf("balance %d disagrees with total %d minus payments",
			after[0].Balance(), after[0].Total())
	}
}

// TestInvoicePostIsIdempotentAndStaffOnly is the write contract. A bursar's
// desktop may replay a POST whose response it never saw (same client-chosen id,
// must not double-bill), and the roles that cannot record a payment must not be
// able to invent the bill it is charged against either — the app hides both
// affordances behind user.isSchoolStaff and the API has to match.
func TestInvoicePostIsIdempotentAndStaffOnly(t *testing.T) {
	r, st := newFeesServer(t)
	staffTok := login(t, r, "admin@solvanta.app", "admin123")
	staff := map[string]string{"Authorization": "Bearer " + staffTok}

	const payload = `{"id":"INV-PROBE-1","studentId":"STU-001","issueDate":"2026-10-01",` +
		`"dueDate":"2026-10-31","term":"Term 1 · 2026/2027",` +
		`"lineItems":[{"name":"Trip levy","amount":250}],"amountPaid":999999}`

	first := do(r, http.MethodPost, "/api/invoices", payload, staff)
	if first.Code != http.StatusCreated {
		t.Fatalf("first raise: got %d %s", first.Code, first.Body.String())
	}
	replay := do(r, http.MethodPost, "/api/invoices", payload, staff)
	if replay.Code != http.StatusCreated {
		t.Fatalf("replay: got %d %s — a client whose response was lost must be able to retry",
			replay.Code, replay.Body.String())
	}

	count := 0
	for _, inv := range st.Invoices() {
		if inv.ID == "INV-PROBE-1" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("replayed invoice exists %d times, want 1", count)
	}

	// amountPaid sent by the client is ignored: it is derived here, or a client
	// could assert a payment the school never took.
	raised := getInvoices(t, r, staff, "?studentId=STU-001")
	var probe domain.Invoice
	for _, inv := range raised {
		if inv.ID == "INV-PROBE-1" {
			probe = inv
		}
	}
	if probe.ID == "" {
		t.Fatalf("raised invoice not readable back: %+v", raised)
	}
	if probe.AmountPaid != 0 {
		t.Fatalf("client-asserted amountPaid %d was stored — it must be derived from payments",
			probe.AmountPaid)
	}

	for _, acct := range []struct{ email, pw string }{
		{"kojo.owusu@school.gh", "student123"},
		{"ama.owusu@school.gh", "parent123"},
	} {
		tok := login(t, r, acct.email, acct.pw)
		rec := do(r, http.MethodPost, "/api/invoices",
			`{"id":"INV-FORBIDDEN","studentId":"STU-001","issueDate":"2026-10-01",`+
				`"dueDate":"2026-10-31","lineItems":[{"name":"Fake","amount":1}]}`,
			map[string]string{"Authorization": "Bearer " + tok})
		if rec.Code != http.StatusForbidden {
			t.Fatalf("%s: got %d %s, want 403", acct.email, rec.Code, rec.Body.String())
		}
	}
}

// TestInvoicePostRejectsMalformed keeps bad bills out at the boundary. An
// invoice for nobody cannot be scoped to a reader, and a date the memory store
// would keep as a string while PostgreSQL rejects it must not depend on which
// store is configured — both answer 400 here, and nothing is written.
func TestInvoicePostRejectsMalformed(t *testing.T) {
	r, st := newFeesServer(t)
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}
	before := len(st.Invoices())

	for name, body := range map[string]string{
		"missing student": `{"id":"INV-BAD-1","issueDate":"2026-10-01","dueDate":"2026-10-31",` +
			`"lineItems":[{"name":"Tuition","amount":100}]}`,
		"missing dates": `{"id":"INV-BAD-2","studentId":"STU-001",` +
			`"lineItems":[{"name":"Tuition","amount":100}]}`,
		"date is not a date": `{"id":"INV-BAD-3","studentId":"STU-001","issueDate":"soon",` +
			`"dueDate":"2026-10-31","lineItems":[]}`,
		"unparseable body": `{not json`,
	} {
		rec := do(r, http.MethodPost, "/api/invoices", body, hdr)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: got %d %s, want 400", name, rec.Code, rec.Body.String())
		}
	}
	if got := len(st.Invoices()); got != before {
		t.Fatalf("malformed invoices reached the store: %d before, %d after", before, got)
	}
}

// TestPaymentsReadsScopePerStudent covers the read side of putting student_id
// on payments: the same scoping as invoices, so a payment history can be shown
// per student without resolving invoices first — and a parent cannot pull
// another family's money by filtering on its student id.
func TestPaymentsReadsScopePerStudent(t *testing.T) {
	r, _ := newFeesServer(t)
	bearer := func(email, pass string) map[string]string {
		return map[string]string{"Authorization": "Bearer " + login(t, r, email, pass)}
	}
	staff := bearer("admin@solvanta.app", "admin123")
	parent := bearer("ama.owusu@school.gh", "parent123")

	all := do(r, http.MethodGet, "/api/payments", "", staff)
	if all.Code != http.StatusOK {
		t.Fatalf("staff payments: got %d %s", all.Code, all.Body.String())
	}
	var staffList []domain.Payment
	if err := json.Unmarshal(all.Body.Bytes(), &staffList); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(staffList) == 0 {
		t.Fatal("staff sees no payments although the seed records four")
	}
	for _, p := range staffList {
		if p.StudentID == "" {
			t.Fatalf("a seeded payment has no student, so no parent could ever see it: %+v", p)
		}
	}

	mine := do(r, http.MethodGet, "/api/payments", "", parent)
	var parentList []domain.Payment
	if err := json.Unmarshal(mine.Body.Bytes(), &parentList); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(parentList) == 0 {
		t.Fatal("parent sees no payments, want their child's")
	}
	for _, p := range parentList {
		if p.StudentID != "STU-001" {
			t.Fatalf("parent was served another student's payment: %+v", p)
		}
	}

	// Filtering by somebody else's student id yields nothing rather than
	// confirming that student exists.
	filtered := do(r, http.MethodGet, "/api/payments?studentId=STU-002", "", parent)
	var foreign []domain.Payment
	if err := json.Unmarshal(filtered.Body.Bytes(), &foreign); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(foreign) != 0 {
		t.Fatalf("parent pulled another family's payments by filter: %+v", foreign)
	}

	// The invoice filter serves one invoice's history to those who may see it.
	byInvoice := do(r, http.MethodGet, "/api/payments?invoiceId=INV-2026T1-STU-001", "", staff)
	var history []domain.Payment
	if err := json.Unmarshal(byInvoice.Body.Bytes(), &history); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(history) != 1 || history[0].InvoiceID != "INV-2026T1-STU-001" {
		t.Fatalf("?invoiceId= gave %+v, want that invoice's payments only", history)
	}
}

// TestInvoiceWriteFailureReturns500WithoutLeaking holds the new write to the
// contract every other payload write follows: a store that fails answers 500,
// never 201 for a bill that was never stored, and the message carries no SQL —
// a 5xx also keeps the client retrying rather than believing the bill exists.
func TestInvoiceWriteFailureReturns500WithoutLeaking(t *testing.T) {
	r := newFailingServer(t, "SaveInvoice")
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}

	// Control: this same server still writes everything else, so the 500 below
	// is the injected failure and not a mis-wired fixture.
	gate := do(r, http.MethodPost, "/api/gate/events",
		`{"studentId":"STU-001","type":"arrival","time":"07:45","date":"2026-10-01"}`, hdr)
	if gate.Code != http.StatusCreated {
		t.Fatalf("control gate event: got %d %s", gate.Code, gate.Body.String())
	}

	rec := do(r, http.MethodPost, "/api/invoices",
		`{"id":"INV-NEVER-WRITTEN","studentId":"STU-001","issueDate":"2026-10-01",`+
			`"dueDate":"2026-10-31","lineItems":[{"name":"Tuition","amount":100}]}`, hdr)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("failed invoice write answered %d %s — the client would believe the bill exists",
			rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, `"error"`) {
		t.Fatalf("500 body is not an error payload: %s", body)
	}
	for _, leak := range []string{"pq:", "INSERT", "SELECT", "connection", "driver", "store."} {
		if strings.Contains(body, leak) {
			t.Fatalf("500 body leaks storage detail %q: %s", leak, body)
		}
	}
}
