package domain

import "time"

// Billing, plans and subscriptions (Phase 4). The machinery is built in full
// but ships switched off: the platform defaults to `testing` mode, where every
// limit check passes and no invoices are generated, while usage is still
// counted so prices can be set from real numbers later.
//
// Money is stored as integer pesewas (100 pesewas = GHS 1), the same unit as
// payments. All the decision logic here is pure so it can be unit-tested
// without a store.

// BillingMode is the platform-wide switch.
const (
	BillingModeTesting = "testing"
	BillingModeLive    = "live"
)

// PlanKind: who a plan is for.
const (
	PlanKindIndependent = "independent"
	PlanKindSchool      = "school"
)

// Subscription statuses.
const (
	SubFree      = "free"
	SubTesting   = "testing"
	SubActive    = "active"
	SubPastDue   = "past_due"
	SubCancelled = "cancelled"
)

// Limit keys (NULL/absent value means unlimited).
const (
	LimitMaxStudents     = "max_students"
	LimitMaxClasses      = "max_classes"
	LimitAIPagesPerMonth = "ai_pages_per_month"
	LimitExportsPerMonth = "exports_per_month"
)

// Billing cycles.
const (
	CycleMonth = "month"
	CycleTerm  = "term"
)

// PlatformSettings is the single platform-wide billing configuration, stored in
// `public` and editable only by the super admin.
type PlatformSettings struct {
	BillingMode string `json:"billingMode"`
	// LiveStartDate is when `live` mode actually begins enforcing (yyyy-MM-dd).
	// Before it, teachers see a warning banner but nothing is blocked.
	LiveStartDate string `json:"liveStartDate,omitempty"`
	// GraceDays is how long a past_due subscription keeps working before blocks
	// apply.
	GraceDays int `json:"graceDays"`
}

// DefaultPlatformSettings is what the platform runs on until the super admin
// changes it: testing mode, free for everyone.
func DefaultPlatformSettings() PlatformSettings {
	return PlatformSettings{BillingMode: BillingModeTesting, GraceDays: 7}
}

// LiveOn reports whether enforcement is active on the given date: the mode is
// `live` and the start date has arrived (an empty start date means immediately).
func (s PlatformSettings) LiveOn(today string) bool {
	if s.BillingMode != BillingModeLive {
		return false
	}
	return s.LiveStartDate == "" || today >= s.LiveStartDate
}

// Plan is a platform-wide plan (in `public`, not per tenant).
type Plan struct {
	ID                   string          `json:"id"`
	Name                 string          `json:"name"`
	Kind                 string          `json:"kind"`
	IsFreeTier           bool            `json:"isFreeTier"`
	PricePerStudentMonth int             `json:"pricePerStudentMonth"` // pesewas
	PricePerStudentTerm  int             `json:"pricePerStudentTerm"`  // pesewas
	Currency             string          `json:"currency"`             // "GHS"
	Active               bool            `json:"active"`
	CreatedAt            string          `json:"createdAt"`
	UpdatedAt            string          `json:"updatedAt"`
	Features             map[string]bool `json:"features"` // feature_key → enabled
	Limits               map[string]*int `json:"limits"`   // limit_key → value (nil = unlimited)
}

// Includes reports whether the plan grants a feature. An absent key is not
// granted.
func (p Plan) Includes(feature string) bool { return p.Features[feature] }

// LimitFor returns the plan's value for a limit key and whether it is
// unlimited (NULL/absent).
func (p Plan) LimitFor(key string) (value int, unlimited bool) {
	v, ok := p.Limits[key]
	if !ok || v == nil {
		return 0, true
	}
	return *v, false
}

// PricePerStudent is the per-student price for a billing cycle (pesewas).
func (p Plan) PricePerStudent(cycle string) int {
	if cycle == CycleTerm {
		return p.PricePerStudentTerm
	}
	return p.PricePerStudentMonth
}

// InvoiceAmount is billable students × the per-student price for the cycle
// (pesewas). Billable students is the peak active count in the period, so
// removing pupils just before billing does not lower the bill.
func InvoiceAmount(p Plan, cycle string, billableStudents int) int {
	if billableStudents < 0 {
		billableStudents = 0
	}
	return billableStudents * p.PricePerStudent(cycle)
}

// SeedTestingPlanID is the id of the seeded free testing plan.
const SeedTestingPlanID = "plan-independent-testing"

// Seeded plan ids. The free independent plan keeps the historical
// SeedTestingPlanID so existing subscriptions (which default to it) resolve.
const (
	PlanIndependentFree = SeedTestingPlanID
	PlanIndependentPro  = "plan-independent-pro"
	PlanSchoolPro       = "plan-school-pro"
	PlanSchoolMax       = "plan-school-max"
	PlanSchoolUltra     = "plan-school-ultra"
)

// allFeaturesOn returns every catalogue feature enabled — the starting point
// the super admin trims per plan. During the testing phase enforcement is off
// (see FeatureAllowed), so seeding everything on blocks nothing; it just gives
// the admin a full checklist to turn features off against before going live.
func allFeaturesOn() map[string]bool {
	features := map[string]bool{}
	for _, f := range AllFeatures {
		features[f] = true
	}
	return features
}

func unlimited() map[string]*int {
	return map[string]*int{
		LimitMaxStudents: nil, LimitMaxClasses: nil,
		LimitAIPagesPerMonth: nil, LimitExportsPerMonth: nil,
	}
}

// TestingIndependentPlan is the free independent plan every self-registered
// teacher starts on: every feature enabled, every limit unlimited, price 0.
func TestingIndependentPlan(now string) Plan {
	return Plan{
		ID: PlanIndependentFree, Name: "Independent — Free", Kind: PlanKindIndependent,
		IsFreeTier: true, Currency: "GHS", Active: true, CreatedAt: now, UpdatedAt: now,
		Features: allFeaturesOn(),
		Limits:   unlimited(),
	}
}

// DefaultPlans is the catalogue seeded at first boot: a free and a paid plan
// for independent teachers, and Pro / Max / Ultra for schools. Every plan
// starts with all features enabled and price 0 — the super admin sets the
// feature split and the prices per plan (and may remove a tier) before live
// billing is switched on, with no code change.
func DefaultPlans(now string) []Plan {
	plan := func(id, name, kind string, free bool) Plan {
		return Plan{
			ID: id, Name: name, Kind: kind, IsFreeTier: free,
			Currency: "GHS", Active: true, CreatedAt: now, UpdatedAt: now,
			Features: allFeaturesOn(), Limits: unlimited(),
		}
	}
	return []Plan{
		TestingIndependentPlan(now),
		plan(PlanIndependentPro, "Independent — Pro", PlanKindIndependent, false),
		plan(PlanSchoolPro, "School — Pro", PlanKindSchool, false),
		plan(PlanSchoolMax, "School — Max", PlanKindSchool, false),
		plan(PlanSchoolUltra, "School — Ultra", PlanKindSchool, false),
	}
}

// Subscription ties a tenant to a plan for a billing period.
type Subscription struct {
	TenantID     string `json:"tenantId"`
	PlanID       string `json:"planId"`
	BillingCycle string `json:"billingCycle"`
	PeriodStart  string `json:"periodStart"`
	PeriodEnd    string `json:"periodEnd"`
	Status       string `json:"status"`
}

// PlanPriceHistory records a price change so it can be shown and so billing is
// never retroactive — a period is always billed at the price effective at its
// start.
type PlanPriceHistory struct {
	PlanID          string `json:"planId"`
	Cycle           string `json:"cycle"`
	PricePerStudent int    `json:"pricePerStudent"`
	EffectiveFrom   string `json:"effectiveFrom"` // yyyy-MM-dd
	ChangedAt       string `json:"changedAt"`
	ChangedBy       string `json:"changedBy"`
}

// PriceAt returns the per-student price in force on a date for a cycle, from the
// history (most recent effective-from that is on or before the date). When no
// history applies it falls back to the plan's current price — so a price change
// dated in the future does not apply to the current period.
func PriceAt(plan Plan, history []PlanPriceHistory, cycle, date string) int {
	best := plan.PricePerStudent(cycle)
	bestFrom := ""
	for _, h := range history {
		if h.PlanID != plan.ID || h.Cycle != cycle {
			continue
		}
		if h.EffectiveFrom <= date && h.EffectiveFrom >= bestFrom {
			best = h.PricePerStudent
			bestFrom = h.EffectiveFrom
		}
	}
	return best
}

// Usage is one tenant's counted activity for one month (yyyy-MM). PeakStudents
// is the highest active-student count seen in the month — the billable figure.
type Usage struct {
	TenantID       string `json:"tenantId"`
	Month          string `json:"month"`
	PeakStudents   int    `json:"peakStudents"`
	Classes        int    `json:"classes"`
	AIPages        int    `json:"aiPages"`
	Exports        int    `json:"exports"`
	OCRCostPesewas int    `json:"ocrCostPesewas"`
}

// GraceExpired reports whether a past_due subscription's configurable grace
// window (days after the period end) has passed on the given date.
func GraceExpired(sub Subscription, graceDays int, today string) bool {
	end, err := time.Parse("2006-01-02", sub.PeriodEnd)
	if err != nil {
		return false
	}
	now, err := time.Parse("2006-01-02", today)
	if err != nil {
		return false
	}
	return now.After(end.AddDate(0, 0, graceDays))
}

// FeatureAllowed decides whether a tenant may use a gated feature right now,
// combining the platform mode, the plan and the subscription status. In testing
// mode (or before the live start date) everything is allowed; usage is counted
// regardless. A cancelled subscription blocks; a past_due one blocks only once
// its configurable grace window (s.GraceDays) has passed.
func FeatureAllowed(s PlatformSettings, plan Plan, sub Subscription, feature, today string) bool {
	if !s.LiveOn(today) {
		return true
	}
	switch sub.Status {
	case SubCancelled:
		return false
	case SubPastDue:
		if GraceExpired(sub, s.GraceDays, today) {
			return false
		}
	}
	return plan.Includes(feature)
}

// LimitAllowed decides whether a new action that consumes a limited resource is
// permitted: unlimited (NULL) always passes, and in testing mode everything
// passes. currentUsage is the count BEFORE this action.
func LimitAllowed(s PlatformSettings, plan Plan, limitKey string, currentUsage int, today string) bool {
	if !s.LiveOn(today) {
		return true
	}
	value, unlimited := plan.LimitFor(limitKey)
	if unlimited {
		return true
	}
	return currentUsage < value
}
