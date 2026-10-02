package httpapi

import (
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/store"
)

// newFeesServer builds the API over a fresh seeded store and hands back the
// store as well. The list endpoints answer only for whoever is asking, so when
// the question is "did a replay land twice?" the store is still the honest
// place to count what was written.
func newFeesServer(t *testing.T) (*gin.Engine, store.Store) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	st := store.New()
	s, err := NewServer(st, Config{})
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return s.Router(), st
}

// TestPaymentReplayIsRecordedOnce is the contract the fees feature rests on.
// The device firm-commits a payment to its local store and keeps pushing until
// the server answers, so the same id arrives more than once by design — a
// timeout with the write already applied, a dropped response, an app restart
// mid-push. Both attempts must be answered 201 (the second is still true: the
// payment IS recorded) and the store must hold it exactly once, because
// recording it twice pays the same collection in twice.
func TestPaymentReplayIsRecordedOnce(t *testing.T) {
	r, st := newFeesServer(t)
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}

	const payload = `{"id":"PAY-REPLAY-1","invoiceId":"INV-TEST-1","amount":150,` +
		`"method":"mobileMoney","reference":"MP261001.442.A7711","paidAt":"2026-10-01 09:41",` +
		`"recordedBy":"Ama Owusu"}`

	first := do(r, http.MethodPost, "/api/payments", payload, hdr)
	if first.Code != http.StatusCreated {
		t.Fatalf("first push: got %d %s", first.Code, first.Body.String())
	}
	second := do(r, http.MethodPost, "/api/payments", payload, hdr)
	if second.Code != http.StatusCreated {
		t.Fatalf("replay: got %d %s — ApiClient drops a 4xx from the outbox, so the money "+
			"would exist on the device and nowhere in the school's records",
			second.Code, second.Body.String())
	}

	// The seed writes its own payments, so count the ones this test pushed:
	// both attempts together must have added exactly one row with this id.
	var mine []domain.Payment
	for _, p := range st.Payments() {
		if p.ID == "PAY-REPLAY-1" {
			mine = append(mine, p)
		}
	}
	if len(mine) != 1 {
		t.Fatalf("replay produced %d copies of one payment, want exactly 1", len(mine))
	}
	if mine[0].Amount != 150 || mine[0].InvoiceID != "INV-TEST-1" ||
		mine[0].Method != "mobileMoney" || mine[0].Reference != "MP261001.442.A7711" ||
		mine[0].PaidAt != "2026-10-01 09:41" || mine[0].RecordedBy != "Ama Owusu" {
		t.Fatalf("stored payment does not match what was sent: %+v", mine[0])
	}
}

// TestPaymentRejectsMalformedMoney keeps bad rows out at the boundary. The
// database's CHECK on amount would surface as a 500, and ApiClient treats a 5xx
// as transient and retries it forever, so the handler has to catch a payment
// with no invoice or no money before it ever reaches storage.
func TestPaymentRejectsMalformedMoney(t *testing.T) {
	r, st := newFeesServer(t)
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}
	before := len(st.Payments())

	for name, body := range map[string]string{
		"missing invoice":  `{"id":"PAY-BAD-1","amount":100,"method":"cash","paidAt":"2026-10-01 09:41"}`,
		"zero amount":      `{"id":"PAY-BAD-2","invoiceId":"INV-TEST-1","amount":0,"method":"cash","paidAt":"2026-10-01 09:41"}`,
		"negative amount":  `{"id":"PAY-BAD-3","invoiceId":"INV-TEST-1","amount":-40,"method":"cash","paidAt":"2026-10-01 09:41"}`,
		"unparseable body": `{not json`,
	} {
		rec := do(r, http.MethodPost, "/api/payments", body, hdr)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: got %d %s, want 400", name, rec.Code, rec.Body.String())
		}
	}
	if got := len(st.Payments()); got != before {
		t.Fatalf("malformed payments reached the store: %d before the probe, %d after", before, got)
	}
}

// TestPaymentRequiresStaff matches the client's own gate: the fees screens only
// offer "Record payment" when user.isSchoolStaff, and the API must refuse what
// the app hides — otherwise a forged request from a student's or parent's
// session could post money against an invoice they do not own.
func TestPaymentRequiresStaff(t *testing.T) {
	r, st := newFeesServer(t)
	before := len(st.Payments())

	for _, acct := range []struct{ email, pw string }{
		{"kojo.owusu@school.gh", "student123"},
		{"ama.owusu@school.gh", "parent123"},
	} {
		tok := login(t, r, acct.email, acct.pw)
		rec := do(r, http.MethodPost, "/api/payments",
			`{"id":"PAY-FORBIDDEN","invoiceId":"INV-TEST-1","amount":999,"method":"cash",`+
				`"paidAt":"2026-10-01 09:41"}`,
			map[string]string{"Authorization": "Bearer " + tok})
		if rec.Code != http.StatusForbidden {
			t.Fatalf("%s: got %d %s, want 403", acct.email, rec.Code, rec.Body.String())
		}
	}
	if got := len(st.Payments()); got != before {
		t.Fatalf("a forbidden role wrote a payment: %d before, %d after", before, got)
	}
}

// TestPaymentWriteFailureReturns500WithoutLeaking holds the new endpoint to the
// same contract as the rest of the write-failure refactor: when the store fails
// to write, the client is told 500 and keeps the item in its outbox to retry,
// never handed a 201 for money that was never recorded — and the generic
// message proves no SQL or driver detail reaches the client. failingStore
// returns before calling through, so a failed payment writes nothing at all.
func TestPaymentWriteFailureReturns500WithoutLeaking(t *testing.T) {
	r := newFailingServer(t, "SavePayment")
	tok := login(t, r, "admin@solvanta.app", "admin123")
	hdr := map[string]string{"Authorization": "Bearer " + tok}

	// Control: this same server still writes everything else, so the 500 below
	// is the injected failure and not a mis-wired fixture.
	gate := do(r, http.MethodPost, "/api/gate/events",
		`{"studentId":"STU-001","type":"arrival","time":"07:45","date":"2026-10-01"}`, hdr)
	if gate.Code != http.StatusCreated {
		t.Fatalf("control gate event: got %d %s", gate.Code, gate.Body.String())
	}

	rec := do(r, http.MethodPost, "/api/payments",
		`{"id":"PAY-NEVER-WRITTEN","invoiceId":"INV-TEST-1","amount":200,"method":"cash",`+
			`"paidAt":"2026-10-01 09:41"}`, hdr)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("failed payment write answered %d %s — the client would believe the money was recorded",
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
