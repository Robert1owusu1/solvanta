// Package payments defines the payment-collection seam for Phase 4. A real
// mobile-money gateway (Paystack or Hubtel) comes later; for now only the
// interface and a deterministic mock exist, so the billing flow can be built
// and tested end to end without taking real money.
package payments

import (
	"context"
	"fmt"
	"sync"
)

// ChargeRequest is a request to collect money from a payer.
type ChargeRequest struct {
	TenantID      string
	AmountPesewas int
	Currency      string // "GHS"
	Reference     string // idempotency key (client-chosen)
	PayerPhone    string // mobile-money number, when known
	Description   string
}

// ChargeResult is the outcome of a collection attempt.
type ChargeResult struct {
	Reference   string
	Status      string // "succeeded" | "pending" | "failed"
	ProviderRef string
}

// Provider collects payments. Implementations must be idempotent on Reference,
// so a retried charge never takes the money twice.
type Provider interface {
	// Name identifies the gateway in logs and on receipts.
	Name() string
	// Charge requests a collection; implementations resolve it however the
	// gateway does (redirect, USSD push, …). The mock resolves synchronously.
	Charge(ctx context.Context, req ChargeRequest) (ChargeResult, error)
}

// MockProvider is the default: it records every charge and succeeds, keyed by
// reference so a replay returns the first result. Used by tests and local dev.
type MockProvider struct {
	mu      sync.Mutex
	byRef   map[string]ChargeResult
	Charges []ChargeRequest // spy, newest last
}

// NewMock returns a ready mock provider.
func NewMock() *MockProvider {
	return &MockProvider{byRef: map[string]ChargeResult{}}
}

func (m *MockProvider) Name() string { return "mock" }

func (m *MockProvider) Charge(_ context.Context, req ChargeRequest) (ChargeResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if req.Reference == "" {
		return ChargeResult{}, fmt.Errorf("payments: a reference is required for idempotency")
	}
	if prev, ok := m.byRef[req.Reference]; ok {
		return prev, nil // idempotent replay
	}
	res := ChargeResult{Reference: req.Reference, Status: "succeeded", ProviderRef: "MOCK-" + req.Reference}
	m.byRef[req.Reference] = res
	m.Charges = append(m.Charges, req)
	return res, nil
}
