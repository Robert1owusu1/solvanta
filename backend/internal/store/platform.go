package store

import (
	"sort"
	"sync"

	"solvanta/backend/internal/domain"
)

// Platform holds the platform-wide billing data that lives in `public`, not in
// any one school: the billing-mode switch, the plan catalogue, per-tenant
// subscriptions, the price-change history and the usage counters. It is shared
// by every tenant and edited only by the super admin.
type Platform interface {
	Settings() domain.PlatformSettings
	SaveSettings(s domain.PlatformSettings) error

	Plans() []domain.Plan
	PlanByID(id string) (domain.Plan, bool)
	SavePlan(p domain.Plan) error
	DeletePlan(id string) error

	PriceHistory() []domain.PlanPriceHistory
	AddPriceHistory(h domain.PlanPriceHistory) error

	Subscription(tenantID string) (domain.Subscription, bool)
	SaveSubscription(s domain.Subscription) error
	Subscriptions() []domain.Subscription

	Usage(tenantID, month string) (domain.Usage, bool)
	SaveUsage(u domain.Usage) error
	AllUsage() []domain.Usage
}

// MemoryPlatform is the in-memory Platform, seeded with testing-mode settings
// and the one free "Independent — Testing" plan.
type MemoryPlatform struct {
	mu       sync.RWMutex
	settings domain.PlatformSettings
	plans    map[string]domain.Plan
	history  []domain.PlanPriceHistory
	subs     map[string]domain.Subscription // tenantID → subscription
	usage    map[string]domain.Usage        // tenantID+"\x00"+month → usage
}

// NewMemoryPlatform returns a platform seeded for the testing phase: free
// access for everyone, usage still counted.
func NewMemoryPlatform(now string) *MemoryPlatform {
	seed := domain.TestingIndependentPlan(now)
	return &MemoryPlatform{
		settings: domain.DefaultPlatformSettings(),
		plans:    map[string]domain.Plan{seed.ID: seed},
		subs:     map[string]domain.Subscription{},
		usage:    map[string]domain.Usage{},
	}
}

func (m *MemoryPlatform) Settings() domain.PlatformSettings {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.settings
}

func (m *MemoryPlatform) SaveSettings(s domain.PlatformSettings) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.settings = s
	return nil
}

func (m *MemoryPlatform) Plans() []domain.Plan {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]domain.Plan, 0, len(m.plans))
	for _, p := range m.plans {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (m *MemoryPlatform) PlanByID(id string) (domain.Plan, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	p, ok := m.plans[id]
	return p, ok
}

func (m *MemoryPlatform) SavePlan(p domain.Plan) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.plans[p.ID] = p
	return nil
}

func (m *MemoryPlatform) DeletePlan(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.plans, id)
	return nil
}

func (m *MemoryPlatform) PriceHistory() []domain.PlanPriceHistory {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return append([]domain.PlanPriceHistory(nil), m.history...)
}

func (m *MemoryPlatform) AddPriceHistory(h domain.PlanPriceHistory) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.history = append(m.history, h)
	return nil
}

func (m *MemoryPlatform) Subscription(tenantID string) (domain.Subscription, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.subs[tenantID]
	return s, ok
}

func (m *MemoryPlatform) SaveSubscription(s domain.Subscription) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.subs[s.TenantID] = s
	return nil
}

func (m *MemoryPlatform) Subscriptions() []domain.Subscription {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]domain.Subscription, 0, len(m.subs))
	for _, s := range m.subs {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].TenantID < out[j].TenantID })
	return out
}

func usageKey(tenantID, month string) string { return tenantID + "\x00" + month }

func (m *MemoryPlatform) Usage(tenantID, month string) (domain.Usage, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	u, ok := m.usage[usageKey(tenantID, month)]
	return u, ok
}

func (m *MemoryPlatform) SaveUsage(u domain.Usage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.usage[usageKey(u.TenantID, u.Month)] = u
	return nil
}

func (m *MemoryPlatform) AllUsage() []domain.Usage {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]domain.Usage, 0, len(m.usage))
	for _, u := range m.usage {
		out = append(out, u)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].TenantID != out[j].TenantID {
			return out[i].TenantID < out[j].TenantID
		}
		return out[i].Month < out[j].Month
	})
	return out
}
