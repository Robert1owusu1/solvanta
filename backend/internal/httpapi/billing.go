package httpapi

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// Billing, plans and subscriptions (Phase 4). Shipped switched off: the
// platform defaults to testing mode, where nothing is blocked but usage is
// still counted. All the pricing/enforcement decisions are in domain/billing.go
// (pure, unit-tested); this file is the API and the store wiring.

func billingMonth() string { return time.Now().Format("2006-01") }

// subFor resolves a tenant's subscription and plan, defaulting an un-assigned
// tenant to the seeded free testing plan.
func (s *Server) subFor(tenantID string) (domain.Subscription, domain.Plan) {
	sub, ok := s.platform.Subscription(tenantID)
	if !ok {
		sub = domain.Subscription{
			TenantID: tenantID, PlanID: domain.SeedTestingPlanID,
			BillingCycle: domain.CycleMonth, Status: domain.SubTesting,
		}
	}
	plan, ok := s.platform.PlanByID(sub.PlanID)
	if !ok {
		plan, _ = s.platform.PlanByID(domain.SeedTestingPlanID)
	}
	return sub, plan
}

// requirePlanFeature blocks an action whose feature the tenant's plan does not
// include — but only once the platform is live (testing mode passes). The
// response carries upgrade: true so the client can show the upgrade sheet.
func (s *Server) requirePlanFeature(feature string) gin.HandlerFunc {
	return func(c *gin.Context) {
		id := s.db(c).School().ID
		sub, plan := s.subFor(id)
		if !domain.FeatureAllowed(s.platform.Settings(), plan, sub, feature, today()) {
			c.JSON(http.StatusForbidden, gin.H{
				"error": "Your plan does not include this feature.", "upgrade": true, "feature": feature})
			c.Abort()
			return
		}
		c.Next()
	}
}

// requirePlanLimit blocks a new action that would exceed a plan limit (live
// mode only; NULL limits and testing mode always pass). count returns the
// current usage before this action.
func (s *Server) requirePlanLimit(limitKey string, count func(c *gin.Context) int) gin.HandlerFunc {
	return func(c *gin.Context) {
		id := s.db(c).School().ID
		_, plan := s.subFor(id)
		if !domain.LimitAllowed(s.platform.Settings(), plan, limitKey, count(c), today()) {
			c.JSON(http.StatusForbidden, gin.H{
				"error": "You have reached your plan's limit.", "upgrade": true, "limit": limitKey})
			c.Abort()
			return
		}
		c.Next()
	}
}

// recordTenantUsage refreshes the peak-student and class counters for the
// request's tenant this month. Called after a student or class write, so the
// billable peak reflects the highest count the tenant ever reached — removing
// pupils before billing cannot lower it.
func (s *Server) recordTenantUsage(c *gin.Context) {
	id := s.db(c).School().ID
	if id == "" {
		return
	}
	month := billingMonth()
	u, _ := s.platform.Usage(id, month)
	u.TenantID, u.Month = id, month
	if n := len(s.db(c).Students()); n > u.PeakStudents {
		u.PeakStudents = n
	}
	if n := len(s.db(c).Classes()); n > u.Classes {
		u.Classes = n
	}
	_ = s.platform.SaveUsage(u)
}

// recordAIUsage counts one AI-marked page (and its OCR cost) for the tenant.
func (s *Server) recordAIUsage(c *gin.Context, pages, costPesewas int) {
	id := s.db(c).School().ID
	if id == "" {
		return
	}
	month := billingMonth()
	u, _ := s.platform.Usage(id, month)
	u.TenantID, u.Month = id, month
	u.AIPages += pages
	u.OCRCostPesewas += costPesewas
	_ = s.platform.SaveUsage(u)
}

// --- Super-admin: platform billing switch ---

func (s *Server) getBilling(c *gin.Context) { sendJSON(c, s.platform.Settings()) }

func (s *Server) putBilling(c *gin.Context) {
	var body domain.PlatformSettings
	if !bind(c, &body) {
		return
	}
	switch body.BillingMode {
	case domain.BillingModeTesting, domain.BillingModeLive:
	default:
		fail(c, http.StatusBadRequest, "billingMode must be testing or live")
		return
	}
	if body.LiveStartDate != "" && !isISODate(body.LiveStartDate) {
		fail(c, http.StatusBadRequest, "liveStartDate must be yyyy-MM-dd")
		return
	}
	if body.GraceDays < 0 {
		body.GraceDays = 0
	}
	if err := s.platform.SaveSettings(body); err != nil {
		fail(c, http.StatusInternalServerError, "Could not save the billing settings")
		return
	}
	s.audit(c, "platform.billing", "platform",
		"Billing mode set to "+body.BillingMode+" (start "+firstNonEmpty(body.LiveStartDate, "now")+")", "")
	sendJSON(c, body)
}

// --- Super-admin: plans ---

func (s *Server) listPlans(c *gin.Context) { sendJSON(c, s.platform.Plans()) }

func (s *Server) createPlan(c *gin.Context) {
	var p domain.Plan
	if !bind(c, &p) {
		return
	}
	if p.Name == "" {
		fail(c, http.StatusBadRequest, "name is required")
		return
	}
	if p.Kind != domain.PlanKindIndependent && p.Kind != domain.PlanKindSchool {
		fail(c, http.StatusBadRequest, "kind must be independent or school")
		return
	}
	p.ID = firstNonEmpty(p.ID, newID("plan"))
	if _, exists := s.platform.PlanByID(p.ID); exists {
		fail(c, http.StatusConflict, "A plan with this id already exists")
		return
	}
	p.Currency = firstNonEmpty(p.Currency, "GHS")
	p.Active = true
	p.CreatedAt, p.UpdatedAt = now(), now()
	if err := s.platform.SavePlan(p); err != nil {
		fail(c, http.StatusInternalServerError, "Could not save the plan")
		return
	}
	s.audit(c, "plan.create", p.ID, "Created plan "+p.Name, "")
	sendCreated(c, p)
}

func (s *Server) updatePlan(c *gin.Context) {
	existing, ok := s.platform.PlanByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Plan not found")
		return
	}
	var p domain.Plan
	if !bind(c, &p) {
		return
	}
	p.ID = existing.ID
	p.CreatedAt = existing.CreatedAt
	p.Currency = firstNonEmpty(p.Currency, existing.Currency)
	p.UpdatedAt = now()
	// A price change is recorded in history and takes effect from the next
	// month — never retroactively.
	nextMonth := time.Now().AddDate(0, 1, 0).Format("2006-01-02")[:8] + "01"
	u := currentUser(c)
	if p.PricePerStudentMonth != existing.PricePerStudentMonth {
		_ = s.platform.AddPriceHistory(domain.PlanPriceHistory{PlanID: p.ID, Cycle: domain.CycleMonth,
			PricePerStudent: p.PricePerStudentMonth, EffectiveFrom: nextMonth, ChangedAt: now(), ChangedBy: u.Name})
	}
	if p.PricePerStudentTerm != existing.PricePerStudentTerm {
		_ = s.platform.AddPriceHistory(domain.PlanPriceHistory{PlanID: p.ID, Cycle: domain.CycleTerm,
			PricePerStudent: p.PricePerStudentTerm, EffectiveFrom: nextMonth, ChangedAt: now(), ChangedBy: u.Name})
	}
	if err := s.platform.SavePlan(p); err != nil {
		fail(c, http.StatusInternalServerError, "Could not save the plan")
		return
	}
	s.audit(c, "plan.update", p.ID, "Updated plan "+p.Name, "")
	sendJSON(c, p)
}

// --- Super-admin: subscriptions (assign a plan to a tenant) ---

func (s *Server) assignPlan(c *gin.Context) {
	var body domain.Subscription
	if !bind(c, &body) {
		return
	}
	if body.TenantID == "" {
		fail(c, http.StatusBadRequest, "tenantId is required")
		return
	}
	if _, ok := s.platform.PlanByID(body.PlanID); !ok {
		fail(c, http.StatusBadRequest, "unknown planId")
		return
	}
	if body.BillingCycle != domain.CycleMonth && body.BillingCycle != domain.CycleTerm {
		body.BillingCycle = domain.CycleMonth
	}
	if body.Status == "" {
		body.Status = domain.SubActive
	}
	if err := s.platform.SaveSubscription(body); err != nil {
		fail(c, http.StatusInternalServerError, "Could not save the subscription")
		return
	}
	s.audit(c, "subscription.assign", body.TenantID, "Assigned plan "+body.PlanID+" to "+body.TenantID, "")
	sendJSON(c, body)
}

// --- Super-admin: usage ---

func (s *Server) platformUsage(c *gin.Context) {
	type row struct {
		domain.Usage
		School string `json:"school"`
		Kind   string `json:"kind"`
	}
	var out []row
	for _, id := range s.tenants.Schools() {
		st, err := s.tenants.For(id)
		if err != nil {
			continue
		}
		sc := st.School()
		month := billingMonth()
		u, _ := s.platform.Usage(id, month)
		u.TenantID, u.Month = id, month
		// Reflect the live counts so the screen is accurate even before any
		// write this month bumped the stored peak.
		if n := len(st.Students()); n > u.PeakStudents {
			u.PeakStudents = n
		}
		if n := len(st.Classes()); n > u.Classes {
			u.Classes = n
		}
		out = append(out, row{Usage: u, School: sc.Name, Kind: sc.EffectiveKind()})
	}
	sendJSON(c, out)
}

// --- Any signed-in user: my billing (Account tab badge + banner) ---

func (s *Server) myBilling(c *gin.Context) {
	id := s.db(c).School().ID
	settings := s.platform.Settings()
	sub, plan := s.subFor(id)
	u, _ := s.platform.Usage(id, billingMonth())
	billable := u.PeakStudents
	sendJSON(c, gin.H{
		"billingMode":   settings.BillingMode,
		"liveOn":        settings.LiveOn(today()),
		"liveStartDate": settings.LiveStartDate,
		"plan":          plan,
		"subscription":  sub,
		"usage":         u,
		"preview": gin.H{
			"month": domain.InvoiceAmount(plan, domain.CycleMonth, billable),
			"term":  domain.InvoiceAmount(plan, domain.CycleTerm, billable),
		},
	})
}
