// Package httpapi exposes the SOLVANTA REST API (Gin). Endpoint groups mirror
// the doc's feature sections; every response uses the same camelCase JSON
// contracts as the Flutter client.
package httpapi

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/ocr"
	"solvanta/backend/internal/store"
)

// tokenTTL is how long a bearer token stays valid.
const tokenTTL = 24 * time.Hour

// Server bundles the store, signer, and session blacklist for the API.
type Server struct {
	store  store.Store
	cfg    Config
	secret []byte

	// ocrs routes a page to Mathpix, Cloud Vision, or the mock. It is built
	// once at startup from the environment: absent credentials are the normal
	// state today and must leave the server answering, not failing to boot.
	ocrs *ocr.Router

	sessionsMu sync.Mutex
	// revoked maps a token's jti to the time it expires (when it can be
	// dropped from the blacklist).
	revoked map[string]time.Time
}

// NewServer builds the API server. When cfg.Secret is empty the server uses a
// fresh random key (invalidating old tokens on restart); in Production that is
// a boot error instead.
func NewServer(s store.Store, cfg Config) (*Server, error) {
	for _, p := range cfg.TrustedProxies {
		if net.ParseIP(p) == nil {
			if _, _, err := net.ParseCIDR(p); err != nil {
				return nil, fmt.Errorf("TRUSTED_PROXIES: %q is not an IP address or CIDR range", p)
			}
		}
	}
	if cfg.Secret == "" {
		if cfg.Production {
			return nil, errors.New("SECRET must be set in production (set SECRET env)")
		}
		// per-process random key: safer than a hardcoded default
		cfg.Secret = randomSecret()
	}
	return &Server{
		store:   s,
		cfg:     cfg,
		secret:  []byte(cfg.Secret),
		ocrs:    ocr.NewRouter(ocr.FromEnv()),
		revoked: map[string]time.Time{},
	}, nil
}

// OCRStatus is the startup summary of which engine serves which route and
// why. Printed once at boot so nobody has to guess whether a key took effect,
// and so a deployment on the mock says so out loud instead of quietly
// pretending to be a paid engine.
func (s *Server) OCRStatus() string {
	return s.ocrs.Status()
}

// sign issues a token for a user for the given ttl.
func (s *Server) sign(u domain.User, ttl time.Duration) string {
	now := time.Now()
	claims, _ := json.Marshal(tokenClaims{
		Sub: u.ID, Exp: now.Add(ttl).Unix(), Iat: now.Unix(), Jti: randomHex(16),
	})
	mac := hmac.New(sha256.New, s.secret)
	mac.Write(claims)
	return base64.RawURLEncoding.EncodeToString(claims) + "." +
		base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// parseToken validates a token and returns its claims, or zero values.
func (s *Server) parseToken(token string) (tokenClaims, bool) {
	parts := strings.SplitN(token, ".", 2)
	if len(parts) != 2 {
		return tokenClaims{}, false
	}
	claims, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || base64.RawURLEncoding.EncodeToString(claims) != parts[0] {
		return tokenClaims{}, false
	}
	want := hmac.New(sha256.New, s.secret)
	want.Write(claims)
	given, err := base64.RawURLEncoding.DecodeString(parts[1])
	// Go's raw base64 decoder ignores the trailing bits a 32-byte HMAC does
	// not use, so several distinct strings decode to the same signature: the
	// final character of the signature may be any of four characters sharing
	// one top nibble ("w", "x", "y", "z" all decode alike). Re-encoding and
	// comparing rejects those twins. Without it a single session would
	// authenticate under many different bearer strings, so any code that
	// compares a token as text — denylists, audit records, caches — would see
	// strings it never issued.
	if err != nil || !hmac.Equal(given, want.Sum(nil)) ||
		base64.RawURLEncoding.EncodeToString(given) != parts[1] {
		return tokenClaims{}, false
	}
	var tc tokenClaims
	if err := json.Unmarshal(claims, &tc); err != nil {
		return tokenClaims{}, false
	}
	if tc.Sub == "" || tc.Jti == "" || tc.Exp < time.Now().Unix() {
		return tokenClaims{}, false
	}
	return tc, true
}

// claimsFromRequest returns the claims of the bearer token on a request.
func (s *Server) claimsFromRequest(c *gin.Context) (tokenClaims, bool) {
	h := c.GetHeader("Authorization")
	token := strings.TrimPrefix(h, "Bearer ")
	return s.parseToken(token)
}

// revoke marks a jti invalid until its expiry.
func (s *Server) revoke(jti string, exp time.Time) {
	s.sessionsMu.Lock()
	defer s.sessionsMu.Unlock()
	if exp.IsZero() || exp.After(s.revoked[jti]) {
		s.revoked[jti] = exp
	}
}

func (s *Server) isRevoked(jti string) bool {
	s.sessionsMu.Lock()
	defer s.sessionsMu.Unlock()
	exp, ok := s.revoked[jti]
	if !ok {
		return false
	}
	if exp.Before(time.Now()) {
		delete(s.revoked, jti)
		return false
	}
	return true
}

const ctxUserKey = "solvanta.user"

// currentUser returns the authenticated user from the context.
func currentUser(c *gin.Context) domain.User {
	v, _ := c.Get(ctxUserKey)
	u, _ := v.(domain.User)
	return u
}

// requireAuth binds the bearer token to the request context and rejects
// revoked or malformed tokens.
func (s *Server) requireAuth() gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		token := strings.TrimPrefix(h, "Bearer ")
		if token == h {
			token = ""
		}
		if token == "" {
			fail(c, http.StatusUnauthorized, "Authorization required")
			c.Abort()
			return
		}
		tc, ok := s.parseToken(token)
		if !ok || s.isRevoked(tc.Jti) {
			fail(c, http.StatusUnauthorized, "Invalid or expired token")
			c.Abort()
			return
		}
		u, ok := s.store.UserByID(tc.Sub)
		if !ok {
			fail(c, http.StatusUnauthorized, "Unknown user")
			c.Abort()
			return
		}
		c.Set(ctxUserKey, u)
		c.Next()
	}
}

// requireRole allows only users with one of the given roles. Every school
// *management* gate lists domain.RoleSuperAdmin explicitly: the platform
// operator may act anywhere (mirroring schoolScope), while purely student-self
// gates (assignment completion, assessment submission) stay student-only so
// an operator can never pollute a learner's records.
func requireRole(roles ...string) gin.HandlerFunc {
	return func(c *gin.Context) {
		u := currentUser(c)
		for _, r := range roles {
			if u.Role == r {
				c.Next()
				return
			}
		}
		fail(c, http.StatusForbidden, "You do not have permission for this action")
		c.Abort()
	}
}

// schoolScope ensures the user belongs to the school being addressed, or is a
// super admin (which may address any school).
func (s *Server) schoolScope() gin.HandlerFunc {
	return func(c *gin.Context) {
		u := currentUser(c)
		schoolID := c.DefaultQuery("schoolId", c.Param("schoolId"))
		if u.IsSuperAdmin() {
			c.Next()
			return
		}
		if u.SchoolID != "" && (schoolID == "" || schoolID == u.SchoolID) {
			c.Next()
			return
		}
		fail(c, http.StatusForbidden, "School outside your scope")
		c.Abort()
	}
}

func (s *Server) userSchool(u domain.User) string {
	if u.SchoolID != "" {
		return u.SchoolID
	}
	if u.IsSuperAdmin() {
		return domain.DefaultSchoolID()
	}
	return u.SchoolID
}

// sendJSON writes a JSON body. Nil slices are emitted as [] so clients can
// always decode list endpoints as arrays, never null.
func sendJSON(c *gin.Context, v any) {
	v = nonNilLists(v)
	c.JSON(http.StatusOK, v)
}

// sendCreated writes 201.
func sendCreated(c *gin.Context, v any) {
	c.JSON(http.StatusCreated, nonNilLists(v))
}

// nonNilLists converts top-level nil slices to empty ones so JSON output is
// always an array for list endpoints.
func nonNilLists(v any) any {
	rv := reflect.ValueOf(v)
	if rv.Kind() == reflect.Slice && rv.IsNil() {
		return reflect.MakeSlice(rv.Type(), 0, 0).Interface()
	}
	return v
}

// fail writes an error body: {"error": "<message>"}.
func fail(c *gin.Context, status int, msg string) {
	c.JSON(status, gin.H{"error": msg})
}

// bind decodes the JSON body, distinguishing oversize bodies (413) from other
// invalid input (400).
func bind(c *gin.Context, v any) bool {
	if err := c.ShouldBindJSON(v); err != nil {
		if isBodyTooLarge(err) {
			fail(c, http.StatusRequestEntityTooLarge, "Request body too large")
		} else {
			fail(c, http.StatusBadRequest, "Invalid request body: "+err.Error())
		}
		return false
	}
	return true
}

// Router registers every route against the store.
func (s *Server) Router() *gin.Engine {
	r := gin.New()
	// Trust only the configured proxies (none by default). Gin otherwise
	// honours X-Forwarded-For from anyone, and ClientIP() feeds the rate
	// limiter below — a spoofable IP would let an attacker reset their own
	// login throttle (and forge audit addresses). The list was validated in
	// NewServer, so this cannot fail.
	_ = r.SetTrustedProxies(s.cfg.TrustedProxies)
	r.Use(gin.Logger(), gin.Recovery(), s.securityHeaders(), s.cors())

	// Liveness stays "ok" while the process is up: the client reads this to
	// decide whether the server is reachable, and treating storage trouble as
	// "down" would push it to offline-only mode right when it should be
	// syncing. Failures are therefore reported alongside, not instead.
	r.GET("/health", func(c *gin.Context) {
		body := gin.H{"status": "ok"}
		if pg, ok := s.store.(*store.Postgres); ok {
			if n, last, at := pg.StoreErrors(); n > 0 {
				body["storageErrors"] = n
				body["lastStorageError"] = last.Error()
				body["lastStorageErrorAt"] = at.UTC().Format(time.RFC3339)
			}
		}
		sendJSON(c, body)
	})

	auth := r.Group("/auth", limitRequestBody())
	{
		auth.POST("/login", s.loginRateLimit(), s.login)
		auth.POST("/logout", s.requireAuth(), s.logout)
		auth.GET("/me", s.requireAuth(), func(c *gin.Context) {
			sendJSON(c, gin.H{"user": currentUser(c)})
		})
	}

	api := r.Group("/api", limitRequestBody())
	api.Use(s.requireAuth(), s.apiRateLimit())

	api.GET("/subjects", func(c *gin.Context) { sendJSON(c, domain.Subjects) })

	school := api.Group("/school", s.schoolScope())
	{
		school.GET("", func(c *gin.Context) { sendJSON(c, s.store.School()) })
		school.PUT("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin), s.updateSchool)
		school.GET("/term", func(c *gin.Context) { sendJSON(c, s.store.Term()) })
		school.PUT("/term", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.updateTerm)
		school.GET("/classes", func(c *gin.Context) { sendJSON(c, s.store.Classes()) })
		school.PUT("/classes/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.saveClass)
		school.DELETE("/classes/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.deleteClass)
	}

	users := api.Group("/users", s.schoolScope())
	{
		users.GET("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.listUsers)
		users.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin), s.createUser)
		users.PATCH("/:id/password", s.changePassword)
		users.POST("/:id/reset-password", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin), s.resetPassword)
		users.PATCH("/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin), s.updateUser)
	}

	students := api.Group("/students", s.schoolScope())
	{
		students.GET("", s.listStudents)
		students.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.createStudent)
		students.GET("/:id", s.studentDetail)
		students.PATCH("/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.updateStudent)
		students.POST("/:id/promote", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.promoteStudent)
		students.POST("/:id/graduate", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.graduateStudent)
		students.POST("/:id/pickup/authorize", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.authorizePickup)
		students.POST("/:id/pickup/revoke", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.revokePickup)
	}

	attendance := api.Group("/attendance", s.schoolScope())
	{
		attendance.GET("", s.listAttendance)
		attendance.GET("/class/:classId/date/:date", s.attendanceForClassDate)
		attendance.PUT("/class/:classId/date/:date", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.saveAttendanceDay)
		attendance.GET("/students/:studentId/history", s.studentAttendanceHistory)
		attendance.GET("/students/:studentId/summary", s.studentAttendanceSummary)
		attendance.POST("/check-in", s.checkIn)
		attendance.POST("/correction", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.attendanceCorrection)
	}

	gate := api.Group("/gate", s.schoolScope())
	{
		gate.GET("/events", s.gateEvents)
		gate.POST("/events", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.createGateEvent)
		gate.GET("/students/:studentId", s.gateForStudent)
	}

	questions := api.Group("/questions", s.schoolScope())
	{
		questions.GET("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff),
			func(c *gin.Context) { sendJSON(c, s.store.Questions()) })
		questions.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.createQuestion)
		questions.PATCH("/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.updateQuestion)
		questions.DELETE("/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher), s.deleteQuestion)
		questions.GET("/ai/requests", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.aiRequests)
		questions.POST("/ai/requests", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.aiRequest)
		questions.POST("/ai/requests/:id/generate", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.aiGenerate)
		questions.POST("/ai/requests/:id/publish", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.aiPublish)
		questions.POST("/ai/requests/:id/reject", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.aiReject)
	}

	assessments := api.Group("/assessments", s.schoolScope())
	{
		assessments.GET("", s.listAssessments)
		assessments.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.createAssessment)
		assessments.PUT("/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.updateAssessment)
		assessments.GET("/:id", s.assessmentDetail)
		assessments.POST("/:id/blueprint", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.blueprintGenerate)
		assessments.POST("/:id/submit", s.submitAssessment)
		assessments.POST("/:id/verdicts", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.markVerdicts)
		assessments.GET("/:id/results", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.assessmentResults)

		// Marking schemes for this assessment
		assessments.POST("/:id/marking-scheme", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.createMarkingScheme)
		assessments.GET("/:id/marking-scheme", s.listMarkingSchemesForAssessment)
	}

	// Marking schemes for assignments (separate from assessment ones)
	assignmentsScheme := api.Group("/assignments/:id/marking-scheme", s.schoolScope())
	{
		assignmentsScheme.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.createMarkingScheme)
		assignmentsScheme.GET("", s.listMarkingSchemesForAssignment)
	}

	// Global marking scheme operations (by scheme ID)
	ms := api.Group("/marking-schemes", s.schoolScope())
	{
		ms.GET("", s.listMarkingSchemes)
		ms.GET("/:id", s.getMarkingScheme)
		ms.PUT("/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.updateMarkingScheme)
		ms.DELETE("/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.deleteMarkingScheme)
	}

	api.GET("/submissions", s.schoolScope(), s.listSubmissions)

	analytics := api.Group("/analytics", s.schoolScope())
	{
		analytics.GET("/students/:studentId/results", s.studentResults)
		analytics.GET("/students/:studentId/weak-topics", s.studentWeakTopics)
		analytics.GET("/classes/:classId/gaps", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.classGaps)
		analytics.GET("/at-risk", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.atRisk)
	}

	interventions := api.Group("/interventions", s.schoolScope())
	{
		interventions.GET("", s.listInterventions)
		interventions.GET("/students/:studentId", s.interventionsForStudent)
		interventions.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.createIntervention)
		interventions.POST("/:id/status", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.updateInterventionStatus)
		interventions.POST("/:id/reassessment", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.attachReassessment)
		interventions.GET("/:id/improvement", s.interventionImprovement)
	}

	comm := api.Group("", s.schoolScope())
	{
		comm.GET("/announcements", s.listAnnouncements)
		comm.POST("/announcements", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.createAnnouncement)
		comm.DELETE("/announcements/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.deleteAnnouncement)
		comm.GET("/messages", s.listMessages)
		comm.POST("/messages", s.sendMessage)
		comm.POST("/messages/:id/receipt", s.messageReceipt)
		comm.GET("/notifications", s.listNotifications)
		comm.GET("/notifications/unread", s.unreadNotifications)
		comm.POST("/notifications/:id/read", s.markNotificationRead)
		comm.POST("/notifications/read-all", s.markAllNotificationsRead)
	}

	assignments := api.Group("/assignments", s.schoolScope())
	{
		assignments.GET("", s.listAssignments)
		assignments.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.createAssignment)
		assignments.DELETE("/:id", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher), s.deleteAssignment)
		assignments.POST("/:id/complete", requireRole(domain.RoleStudent), s.completeAssignment)
		assignments.DELETE("/:id/complete", requireRole(domain.RoleStudent), s.uncompleteAssignment)
	}

	// Collections stored for the client without a modelled table (records.go).
	records := api.Group("/records", s.schoolScope())
	{
		records.GET("/:kind", s.listRecords)
		records.PUT("/:kind/:id", s.saveRecord)
		records.DELETE("/:kind/:id", s.deleteRecord)
	}
	api.PUT("/scans/:id/image", s.schoolScope(), s.putScanImage)
	api.GET("/scans/:id/image", s.schoolScope(), s.getScanImage)

	// Assignment submissions carry any number of photographed pages, so each
	// page has its own photo under a composite key (see submissionPageKey).
	// Same scope and write rules as a scan — see putScanImage.
	api.PUT("/assignment-submissions/:id/pages/:page/image", s.schoolScope(),
		s.putSubmissionPageImage)
	api.GET("/assignment-submissions/:id/pages/:page/image", s.schoolScope(),
		s.getSubmissionPageImage)

	// Fees (client: lib/features/fees). The device pushes payments from its
	// sync outbox; the reads are scoped per student inside the handlers (see
	// studentVisible) so a parent or a pupil sees only their own money. The
	// role allow-list on a write is IsSchoolStaff() — the same five roles the
	// client's fee screens gate the "Record payment" affordance on, so the API
	// never rejects an action the app just offered, nor accepts one it hides.
	payments := api.Group("/payments", s.schoolScope())
	{
		payments.GET("", s.listPayments)
		payments.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.createPayment)
	}

	// Invoices are the bill, payments against it are the money — the two
	// halves of one fee screen, hence the same scoping and the same write
	// allow-list as /payments above.
	invoices := api.Group("/invoices", s.schoolScope())
	{
		invoices.GET("", s.listInvoices)
		invoices.GET("/:id", s.invoiceDetail)
		invoices.POST("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.createInvoice)
	}

	reports := api.Group("/reports", s.schoolScope())
	{
		reports.GET("/students/:studentId/report-card", s.studentReportCard)
		reports.GET("/assessments/:id/class-results", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher, domain.RoleTeacher, domain.RoleStaff), s.classResultsReport)
	}

	audit := api.Group("/audit", s.schoolScope())
	audit.GET("", requireRole(domain.RoleSuperAdmin, domain.RoleSchoolAdmin, domain.RoleHeadteacher),
		func(c *gin.Context) { sendJSON(c, s.store.AuditLogs()) })

	return r
}
