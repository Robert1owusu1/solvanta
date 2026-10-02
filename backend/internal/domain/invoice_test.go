package domain

import "testing"

// TestInvoiceResolveStatus pins the status rule the client's
// Invoice.resolveStatus implements — paid / overdue / partial / due — against
// explicit dates. The HTTP read side derives this from the wall clock, so a
// test written against "today" would quietly start asserting a different case
// once the seed dates fall further behind; these branch cases belong here.
func TestInvoiceResolveStatus(t *testing.T) {
	const today = "2026-10-01"
	for _, tc := range []struct {
		name string
		inv  Invoice
		want string
	}{
		{
			name: "settled bill is paid whatever the due date",
			inv:  Invoice{DueDate: "2026-09-01", AmountPaid: 500, LineItems: []FeeLineItem{{Name: "Tuition", Amount: 500}}},
			want: InvoiceStatusPaid,
		},
		{
			name: "overpaid settles rather than going negative",
			inv:  Invoice{DueDate: "2026-09-01", AmountPaid: 700, LineItems: []FeeLineItem{{Amount: 500}}},
			want: InvoiceStatusPaid,
		},
		{
			name: "part-paid past due is overdue, not partial",
			inv:  Invoice{DueDate: "2026-09-30", AmountPaid: 400, LineItems: []FeeLineItem{{Amount: 1000}}},
			want: InvoiceStatusOverdue,
		},
		{
			name: "the day after the due date is overdue",
			inv:  Invoice{DueDate: "2026-09-30", AmountPaid: 0, LineItems: []FeeLineItem{{Amount: 1000}}},
			want: InvoiceStatusOverdue,
		},
		{
			name: "part-paid within terms is partial",
			inv:  Invoice{DueDate: "2026-10-31", AmountPaid: 400, LineItems: []FeeLineItem{{Amount: 1000}}},
			want: InvoiceStatusPartial,
		},
		{
			name: "untouched bill within terms is due",
			inv:  Invoice{DueDate: "2026-10-31", AmountPaid: 0, LineItems: []FeeLineItem{{Amount: 1000}}},
			want: InvoiceStatusDue,
		},
		{
			name: "due today is not yet overdue",
			inv:  Invoice{DueDate: today, AmountPaid: 0, LineItems: []FeeLineItem{{Amount: 1000}}},
			want: InvoiceStatusDue,
		},
		{
			name: "a bill with no due date can never be overdue",
			inv:  Invoice{DueDate: "", AmountPaid: 0, LineItems: []FeeLineItem{{Amount: 1000}}},
			want: InvoiceStatusDue,
		},
	} {
		if got := tc.inv.ResolveStatus(today); got != tc.want {
			t.Errorf("%s: ResolveStatus(%q) = %q, want %q", tc.name, today, got, tc.want)
		}
	}
}

// TestInvoiceWithDerivedSumsOnlyItsOwnPayments is the derivation the read side
// is built on: the amount comes from the payments recorded against THIS
// invoice, and the status follows from that sum — never from a value written
// when the bill was raised.
func TestInvoiceWithDerivedSumsOnlyItsOwnPayments(t *testing.T) {
	mine := Invoice{ID: "INV-1", StudentID: "STU-001", DueDate: "2026-10-31",
		LineItems: []FeeLineItem{{Name: "Tuition", Amount: 1000}}}
	payments := []Payment{
		{ID: "P1", InvoiceID: "INV-1", Amount: 400},
		{ID: "P2", InvoiceID: "INV-1", Amount: 100},
		{ID: "P3", InvoiceID: "INV-OTHER", Amount: 9999}, // somebody else's money
	}

	got := mine.WithDerived(payments, "2026-10-01")
	if got.AmountPaid != 500 {
		t.Errorf("amountPaid = %d, want 500 — a payment against another invoice was counted",
			got.AmountPaid)
	}
	if got.Status != InvoiceStatusPartial {
		t.Errorf("status = %q, want %q", got.Status, InvoiceStatusPartial)
	}
	if got.Balance() != 500 {
		t.Errorf("balance = %d, want 500", got.Balance())
	}
	// The input invoice is unchanged: derivation is a read, not a mutation.
	if mine.AmountPaid != 0 || mine.Status != "" {
		t.Errorf("WithDerived mutated the stored invoice: %+v", mine)
	}
}
