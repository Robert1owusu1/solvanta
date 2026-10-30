package httpapi

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// createPayment records one money movement against an invoice (fees module).
//
// This is the route the sync outbox replays `payment.record` to. The cashier's
// device firm-commits the payment locally and pushes it whenever it next gets
// a connection, so the same id legitimately arrives more than once — after a
// timeout, a dropped response, or an app restart mid-push. SavePayment ignores
// an id it has already written, and answering 201 again is the honest reply to
// "is this payment recorded?": yes, once, and here it is.
//
// Before this handler existed, every one of those replays landed on 404, which
// ApiClient treats as a permanent rejection and drops from the outbox — the
// cash existed in the cashier's hand and in no other record the school owns.
func (s *Server) createPayment(c *gin.Context) {
	var body domain.Payment
	if !bind(c, &body) {
		return
	}
	// Rejected up front rather than left to the database's CHECK: a payment
	// with no invoice or no money is malformed at the source, and a 400 tells
	// the client it sent something wrong instead of retrying it forever.
	if body.InvoiceID == "" {
		fail(c, http.StatusBadRequest, "invoiceId is required")
		return
	}
	if body.Amount <= 0 {
		fail(c, http.StatusBadRequest, "amount must be greater than zero")
		return
	}
	u := currentUser(c)
	p := domain.Payment{
		// Honour a client-supplied id so a retried push is idempotent, the
		// same contract as POST /api/gate/events.
		ID: firstNonEmpty(body.ID, newID("PAY")),
		// Taken as sent, never validated against the students table: a client
		// may know a student this server has not received yet, and rejecting
		// the payment over its index would drop the money with the 4xx.
		StudentID:  body.StudentID,
		InvoiceID:  body.InvoiceID,
		Amount:     body.Amount,
		Method:     firstNonEmpty(body.Method, "cash"),
		Reference:  body.Reference,
		PaidAt:     firstNonEmpty(body.PaidAt, now()),
		RecordedBy: firstNonEmpty(body.RecordedBy, u.Name),
	}
	if writeFailed(c, s.db(c).SavePayment(p)) {
		return
	}
	s.audit(c, "payment.record", p.ID,
		"Recorded "+itoa(p.Amount)+" GHS against invoice "+p.InvoiceID, p.Reference)
	sendCreated(c, p)
}

// studentVisible is the one rule every fees read applies: staff see every
// student (optionally narrowed by ?studentId=), a parent their own children, a
// student only themselves. A student outside the caller's scope is simply not
// in the result instead of raising a 403 — a list answers "here is what you
// may see", and an error naming an id would confirm that the id exists.
//
// An empty studentId (a payment recorded before the API tracked students)
// matches nobody but staff, which is the honest answer for a record attributed
// to nobody.
func studentVisible(u domain.User, studentID, want string) bool {
	if want != "" && want != studentID {
		return false
	}
	switch {
	case u.IsSchoolStaff():
		return true
	case u.Role == domain.RoleParent:
		for _, id := range u.StudentIDs {
			if id == studentID {
				return true
			}
		}
		return false
	case u.Role == domain.RoleStudent:
		return stringToStudentID(u.ID) == studentID
	}
	return false
}

// listInvoices returns the term's invoices for the students the caller may
// see, optionally narrowed by ?studentId=. Amounts and statuses arrive
// derived — summed from the payments table, resolved from the due date — so
// the bill a bursar sees on one device is the bill a parent sees on another.
func (s *Server) listInvoices(c *gin.Context) {
	u := currentUser(c)
	want := c.Query("studentId")
	all := s.db(c).Invoices()
	out := make([]domain.Invoice, 0, len(all))
	for _, inv := range all {
		if studentVisible(u, inv.StudentID, want) {
			out = append(out, inv)
		}
	}
	sendJSON(c, out)
}

// invoiceDetail returns one invoice, for the detail screen. 404 for an id that
// does not exist and 403 for one that exists but belongs to another student,
// matching the order interventions.go answers in.
func (s *Server) invoiceDetail(c *gin.Context) {
	inv, ok := s.db(c).InvoiceByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Invoice not found")
		return
	}
	if !studentVisible(currentUser(c), inv.StudentID, "") {
		fail(c, http.StatusForbidden, "Not your student")
		return
	}
	sendJSON(c, inv)
}

// createInvoice raises an invoice: the write side of the same table
// listInvoices reads.
//
// The client keeps its own invoices and does not push them yet, so this route
// exists for anything that bills outside a phone — a bursar's desktop, an
// import — and for the day the app does sync them. It is idempotent on the
// client-chosen id for exactly that reason: an offline-first client may replay
// a POST whose response it never received, and an invoice's terms are corrected
// rather than re-minted, so a replay upserts instead of duplicating.
func (s *Server) createInvoice(c *gin.Context) {
	var body domain.Invoice
	if !bind(c, &body) {
		return
	}
	// Rejected up front rather than left to the database, for both reasons a
	// rejection here matters: an invoice for nobody cannot be scoped to a
	// reader, and a date the memory store would store but PostgreSQL would
	// reject must not depend on which store is configured.
	if body.StudentID == "" {
		fail(c, http.StatusBadRequest, "studentId is required")
		return
	}
	if !isISODate(body.IssueDate) || !isISODate(body.DueDate) {
		fail(c, http.StatusBadRequest, "issueDate and dueDate must be yyyy-MM-dd")
		return
	}
	inv := domain.Invoice{
		ID:        firstNonEmpty(body.ID, newID("INV")),
		StudentID: body.StudentID,
		IssueDate: body.IssueDate,
		DueDate:   body.DueDate,
		LineItems: body.LineItems,
		Term:      body.Term,
	}
	// amountPaid and status are what the read side derives, so anything sent
	// for them is dropped rather than trusted — otherwise a client could
	// assert a payment this school never received.
	inv.Status = inv.ResolveStatus(today())
	if writeFailed(c, s.db(c).SaveInvoice(inv)) {
		return
	}
	s.audit(c, "invoice.create", inv.ID,
		"Raised "+itoa(inv.Total())+" GHS for student "+inv.StudentID, inv.Term)
	sendCreated(c, inv)
}

// listPayments returns recorded payments, scoped per student by exactly the
// same rule as invoices, and optionally narrowed by ?invoiceId= for the history
// shown under one invoice.
func (s *Server) listPayments(c *gin.Context) {
	u := currentUser(c)
	wantStudent := c.Query("studentId")
	wantInvoice := c.Query("invoiceId")
	all := s.db(c).Payments()
	out := make([]domain.Payment, 0, len(all))
	for _, p := range all {
		if wantInvoice != "" && p.InvoiceID != wantInvoice {
			continue
		}
		if studentVisible(u, p.StudentID, wantStudent) {
			out = append(out, p)
		}
	}
	sendJSON(c, out)
}
