package payments

import (
	"context"
	"testing"
)

func TestMockChargeSucceedsAndIsIdempotent(t *testing.T) {
	m := NewMock()
	req := ChargeRequest{TenantID: "WS-1", AmountPesewas: 9000, Currency: "GHS", Reference: "inv-1"}
	r1, err := m.Charge(context.Background(), req)
	if err != nil || r1.Status != "succeeded" {
		t.Fatalf("charge = %+v, %v", r1, err)
	}
	// A replay of the same reference returns the first result, charges once.
	r2, _ := m.Charge(context.Background(), req)
	if r2 != r1 {
		t.Errorf("replay = %+v, want the first result %+v", r2, r1)
	}
	if len(m.Charges) != 1 {
		t.Errorf("recorded %d charges, want 1 (idempotent)", len(m.Charges))
	}
}

func TestMockRequiresReference(t *testing.T) {
	if _, err := NewMock().Charge(context.Background(), ChargeRequest{}); err == nil {
		t.Error("a charge with no reference must error (idempotency key required)")
	}
}
