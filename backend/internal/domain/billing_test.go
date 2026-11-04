package domain

import "testing"

func ptr(n int) *int { return &n }

// A paid plan: GHS 2/student/month, GHS 5/student/term, 50 students max, the
// AI feature on but exports off.
func paidPlan() Plan {
	return Plan{
		ID: "paid", Name: "Paid", Kind: PlanKindIndependent, Currency: "GHS", Active: true,
		PricePerStudentMonth: 200, PricePerStudentTerm: 500,
		Features: map[string]bool{FeatMarkingAI: true, FeatExportXlsx: false},
		Limits:   map[string]*int{LimitMaxStudents: ptr(50), LimitAIPagesPerMonth: nil},
	}
}

func live() PlatformSettings {
	return PlatformSettings{BillingMode: BillingModeLive, GraceDays: 7}
}
func testingMode() PlatformSettings { return DefaultPlatformSettings() }

func TestTestingModeBlocksNothing(t *testing.T) {
	p := paidPlan()
	sub := Subscription{Status: SubCancelled} // even cancelled is fine in testing
	if !FeatureAllowed(testingMode(), p, sub, FeatExportXlsx, "2026-10-01") {
		t.Error("testing mode must allow a disabled feature")
	}
	if !LimitAllowed(testingMode(), p, LimitMaxStudents, 9999, "2026-10-01") {
		t.Error("testing mode must allow an over-limit action")
	}
}

func TestNullLimitIsUnlimited(t *testing.T) {
	p := paidPlan()
	// ai_pages is NULL → unlimited, even live.
	if !LimitAllowed(live(), p, LimitAIPagesPerMonth, 1_000_000, "2026-10-01") {
		t.Error("a NULL limit must be unlimited")
	}
	// max_students is 50 → the 50th (index 50) action is blocked live.
	if !LimitAllowed(live(), p, LimitMaxStudents, 49, "2026-10-01") {
		t.Error("under the limit should pass")
	}
	if LimitAllowed(live(), p, LimitMaxStudents, 50, "2026-10-01") {
		t.Error("at the limit a new action should be blocked live")
	}
}

func TestDisabledFeatureBlockedLiveOnly(t *testing.T) {
	p := paidPlan()
	sub := Subscription{Status: SubActive}
	if FeatureAllowed(live(), p, sub, FeatExportXlsx, "2026-10-01") {
		t.Error("a disabled feature must be blocked in live mode")
	}
	if !FeatureAllowed(live(), p, sub, FeatMarkingAI, "2026-10-01") {
		t.Error("an enabled feature must be allowed")
	}
	// Same disabled feature in testing mode is allowed.
	if !FeatureAllowed(testingMode(), p, sub, FeatExportXlsx, "2026-10-01") {
		t.Error("testing mode must not block a disabled feature")
	}
}

func TestPriceCalculationBothCyclesAndPeak(t *testing.T) {
	p := paidPlan()
	// 45 students: GHS 2/month → 9000 pesewas; GHS 5/term → 22500 pesewas.
	if got := InvoiceAmount(p, CycleMonth, 45); got != 45*200 {
		t.Errorf("monthly = %d, want %d", got, 45*200)
	}
	if got := InvoiceAmount(p, CycleTerm, 45); got != 45*500 {
		t.Errorf("termly = %d, want %d", got, 45*500)
	}
	// Peak rule: the bill uses the peak count, not the current one. (The caller
	// passes peak; here we just confirm the amount tracks the number given.)
	if InvoiceAmount(p, CycleMonth, 50) <= InvoiceAmount(p, CycleMonth, 30) {
		t.Error("a higher peak must bill more")
	}
}

func TestPriceChangeNotRetroactive(t *testing.T) {
	p := paidPlan() // current month price 200
	history := []PlanPriceHistory{
		{PlanID: "paid", Cycle: CycleMonth, PricePerStudent: 300, EffectiveFrom: "2026-11-01"},
	}
	// A period starting in October is billed at the old 200.
	if got := PriceAt(p, history, CycleMonth, "2026-10-01"); got != 200 {
		t.Errorf("Oct price = %d, want 200 (change not yet effective)", got)
	}
	// From November the new 300 applies.
	if got := PriceAt(p, history, CycleMonth, "2026-11-15"); got != 300 {
		t.Errorf("Nov price = %d, want 300", got)
	}
}

func TestGracePeriod(t *testing.T) {
	p := paidPlan()
	sub := Subscription{Status: SubPastDue, PeriodEnd: "2026-10-31"}
	s := live() // grace 7 days
	// Within grace (Nov 3) the feature still works.
	if !FeatureAllowed(s, p, sub, FeatMarkingAI, "2026-11-03") {
		t.Error("past_due within grace should still allow")
	}
	// After grace (Nov 10) it is blocked.
	if FeatureAllowed(s, p, sub, FeatMarkingAI, "2026-11-10") {
		t.Error("past_due after grace should block")
	}
}

func TestTestingToLiveRespectsStartDate(t *testing.T) {
	p := paidPlan()
	sub := Subscription{Status: SubActive}
	s := PlatformSettings{BillingMode: BillingModeLive, LiveStartDate: "2026-12-01", GraceDays: 7}
	// Before the start date, enforcement is off (disabled feature still allowed).
	if !FeatureAllowed(s, p, sub, FeatExportXlsx, "2026-11-20") {
		t.Error("before the live start date nothing should be blocked")
	}
	// On/after it, enforcement kicks in.
	if FeatureAllowed(s, p, sub, FeatExportXlsx, "2026-12-01") {
		t.Error("from the live start date a disabled feature must block")
	}
}

func TestSeedTestingPlanIsFullyOpen(t *testing.T) {
	p := TestingIndependentPlan("2026-10-01 10:00")
	if !p.IsFreeTier || p.PricePerStudentMonth != 0 {
		t.Error("the seed plan must be a free tier at price 0")
	}
	for _, f := range AllFeatures {
		if !p.Includes(f) {
			t.Errorf("seed plan should include every feature, missing %s", f)
		}
	}
	if _, unlimited := p.LimitFor(LimitMaxStudents); !unlimited {
		t.Error("seed plan limits must all be unlimited")
	}
}
