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
		ID:         firstNonEmpty(body.ID, newID("PAY")),
		InvoiceID:  body.InvoiceID,
		Amount:     body.Amount,
		Method:     firstNonEmpty(body.Method, "cash"),
		Reference:  body.Reference,
		PaidAt:     firstNonEmpty(body.PaidAt, now()),
		RecordedBy: firstNonEmpty(body.RecordedBy, u.Name),
	}
	if writeFailed(c, s.store.SavePayment(p)) {
		return
	}
	s.audit(c, "payment.record", p.ID,
		"Recorded "+itoa(p.Amount)+" GHS against invoice "+p.InvoiceID, p.Reference)
	sendCreated(c, p)
}
