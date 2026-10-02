// Package store provides persistence for the backend. A Store interface keeps
// the API layer independent of storage, with two implementations: the in-memory
// one, seeded with the same data the Flutter app generates locally so the API
// is instantly runnable for development, and a PostgreSQL one — chosen when
// POSTGRES_DSN is set — over the schema in migrations/.
package store

import (
	"sort"
	"strings"
	"sync"
	"time"

	"solvanta/backend/internal/domain"
)

// Store is the persistence contract used by the API handlers.
//
// Writes that ARE the request's payload return an error, so a handler can
// answer 500 rather than claim success for a row that was never written.
// Reads stay void: a stale read and a lost write are different problems, and
// only the latter silently corrupts school records.
//
// AddAudit and AddNotification are the deliberate exception. They are incurred
// after the primary write by *other* operations, so failing the parent for
// them would make a client replay a request that already succeeded — a
// duplicate announcement or message. They stay best-effort and are reported
// through Postgres.StoreErrors(), which /health exposes.
type Store interface {
	// School & term
	School() domain.School
	SaveSchool(s domain.School) error
	Term() domain.SchoolTerm
	SaveTerm(t domain.SchoolTerm) error

	// Users (doc §9)
	Users() []domain.User
	UserByID(id string) (domain.User, bool)
	UserByEmail(email string) (domain.User, bool)
	SaveUser(u domain.User) error

	// Classes
	Classes() []domain.ClassRoom
	ClassByID(id string) (domain.ClassRoom, bool)
	SaveClass(c domain.ClassRoom) error

	// Students (doc §10)
	Students() []domain.Student
	StudentByID(id string) (domain.Student, bool)
	StudentsByParentUser(id string) []domain.Student
	SaveStudent(s domain.Student) error

	// Attendance (doc §12)
	Attendance() []domain.AttendanceRecord
	AttendanceForClassDate(classID, date string) []domain.AttendanceRecord
	SaveAttendance(records []domain.AttendanceRecord) error                // merge (bootstrap/seed), never deletes
	SaveDay(classID, date string, records []domain.AttendanceRecord) error // replace one day

	// Gate (doc §13)
	GateEvents() []domain.GateEvent
	GateForStudent(id string) []domain.GateEvent
	AddGateEvent(e domain.GateEvent) error

	// Questions + AI generation (doc §17, §43)
	Questions() []domain.Question
	QuestionByID(id string) (domain.Question, bool)
	SaveQuestion(q domain.Question) error
	DeleteQuestion(id string) error
	AIRequests() []domain.GenRequest
	AIRequestByID(id string) (domain.GenRequest, bool)
	SaveAIRequest(r domain.GenRequest) error

	// Assessments (doc §16)
	Assessments() []domain.Assessment
	AssessmentByID(id string) (domain.Assessment, bool)
	SaveAssessment(a domain.Assessment) error

	// Submissions (doc §26)
	Submissions() []domain.Submission
	SubmissionFor(assessmentID, studentID string) (domain.Submission, bool)
	SaveSubmission(s domain.Submission) error

	// Interventions (doc §31)
	Interventions() []domain.Intervention
	InterventionByID(id string) (domain.Intervention, bool)
	InterventionsForStudent(id string) []domain.Intervention
	SaveIntervention(i domain.Intervention) error

	// Communication (doc §40)
	Messages() []domain.Message
	SaveMessage(m domain.Message) error
	Announcements() []domain.Announcement
	AddAnnouncement(a domain.Announcement) error
	Notifications() []domain.Notification
	AddNotification(n domain.Notification) // best-effort side effect, see above
	SetNotificationRead(id string) error

	// Assignments (doc §41)
	Assignments() []domain.Assignment
	AssignmentByID(id string) (domain.Assignment, bool)
	SaveAssignment(a domain.Assignment) error

	// Fees & payments (client's fees module). The handler scopes these per
	// student, so like Students() the store hands back whole collections;
	// invoice amounts and statuses are derived (payments summed, status
	// computed) rather than stored — see domain.Invoice.
	Invoices() []domain.Invoice
	InvoiceByID(id string) (domain.Invoice, bool)
	SaveInvoice(inv domain.Invoice) error
	Payments() []domain.Payment
	SavePayment(p domain.Payment) error // idempotent: the client owns the id

	// Audit (doc §49)
	AuditLogs() []domain.AuditEntry
	AddAudit(e domain.AuditEntry) // best-effort side effect, see above

	// Refresh-token sessions (auth state, opaque + stored hashed)
	SaveRefreshToken(hash, userID string, expiresAt int64) error
	RefreshTokenLookup(hash string) (userID string, expiresAt int64, ok bool)
	DeleteRefreshToken(hash string) error
	DeleteRefreshTokensForUser(userID string) error
}

// Memory is an in-memory Store seeded identically to the client app.
type Memory struct {
	mu sync.RWMutex

	school        domain.School
	term          domain.SchoolTerm
	users         []domain.User
	classes       []domain.ClassRoom
	students      []domain.Student
	attendance    []domain.AttendanceRecord
	gate          []domain.GateEvent
	questions     []domain.Question
	aiRequests    []domain.GenRequest
	assessments   []domain.Assessment
	submissions   []domain.Submission
	interventions []domain.Intervention
	messages      []domain.Message
	announcements []domain.Announcement
	notifications []domain.Notification
	assignments   []domain.Assignment
	invoices      []domain.Invoice
	payments      []domain.Payment
	audit         []domain.AuditEntry
	refreshTokens map[string]refreshRecord
}

type refreshRecord struct {
	UserID    string
	ExpiresAt int64
}

// New returns a fresh in-memory store, seeded with development data.
// New returns a store loaded with the demo dataset (dev default).
func New() *Memory {
	m := NewUnseeded()
	m.seed()
	return m
}

// NewUnseeded returns an empty store. Production boots from this so a server
// never materialises the demo accounts (super@solvanta.app/super123,
// admin@solvanta.app/admin123, …) unless seeding was explicitly requested.
func NewUnseeded() *Memory {
	return &Memory{}
}

func (m *Memory) School() domain.School {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.school
}

func (m *Memory) SaveSchool(s domain.School) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.school = s

	return nil
}

func (m *Memory) Term() domain.SchoolTerm {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.term
}

func (m *Memory) SaveTerm(t domain.SchoolTerm) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.term = t

	return nil
}

func (m *Memory) Users() []domain.User {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.users
}

func (m *Memory) UserByID(id string) (domain.User, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, u := range m.users {
		if u.ID == id {
			return u, true
		}
	}
	return domain.User{}, false
}

func (m *Memory) UserByEmail(email string) (domain.User, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, u := range m.users {
		if strings.EqualFold(u.Email, email) {
			return u, true
		}
	}
	return domain.User{}, false
}

func (m *Memory) SaveUser(u domain.User) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.users = upsert(m.users, u.ID, u)

	return nil
}

func (m *Memory) Classes() []domain.ClassRoom {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.classes
}

func (m *Memory) ClassByID(id string) (domain.ClassRoom, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, c := range m.classes {
		if c.ID == id {
			return c, true
		}
	}
	return domain.ClassRoom{}, false
}

func (m *Memory) SaveClass(c domain.ClassRoom) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.classes = upsert(m.classes, c.ID, c)

	return nil
}

func (m *Memory) Students() []domain.Student {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.students
}

func (m *Memory) StudentByID(id string) (domain.Student, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, s := range m.students {
		if s.ID == id {
			return s, true
		}
	}
	return domain.Student{}, false
}

func (m *Memory) StudentsByParentUser(id string) []domain.Student {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []domain.Student
	for _, s := range m.students {
		if s.ParentUserID == id {
			out = append(out, s)
		}
	}
	return out
}

func (m *Memory) SaveStudent(s domain.Student) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.students = upsert(m.students, s.ID, s)

	return nil
}

func (m *Memory) Attendance() []domain.AttendanceRecord {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.attendance
}

func (m *Memory) AttendanceForClassDate(classID, date string) []domain.AttendanceRecord {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []domain.AttendanceRecord
	for _, r := range m.attendance {
		if r.ClassID == classID && r.Date == date {
			out = append(out, r)
		}
	}
	return out
}

// SaveAttendance merges records into the log, mirroring the Postgres bootstrap
// path: a student/day that already has a record is left alone and nothing is
// deleted, so re-running the seed is idempotent instead of replacing (and so
// wiping) every attendance record the store holds.
func (m *Memory) SaveAttendance(records []domain.AttendanceRecord) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	type dayKey struct{ student, date string }
	present := make(map[dayKey]bool, len(m.attendance))
	for _, r := range m.attendance {
		present[dayKey{r.StudentID, r.Date}] = true
	}
	for _, r := range records {
		k := dayKey{r.StudentID, r.Date}
		if present[k] {
			continue
		}
		present[k] = true
		m.attendance = append(m.attendance, r)
	}

	return nil
}

func (m *Memory) SaveDay(classID, date string, records []domain.AttendanceRecord) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]domain.AttendanceRecord, 0, len(m.attendance))
	for _, r := range m.attendance {
		if !(r.ClassID == classID && r.Date == date) {
			out = append(out, r)
		}
	}
	out = append(out, records...)
	m.attendance = out

	return nil
}

func (m *Memory) GateEvents() []domain.GateEvent {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.gate
}

func (m *Memory) GateForStudent(id string) []domain.GateEvent {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []domain.GateEvent
	for _, e := range m.gate {
		if e.StudentID == id {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[j].Date+out[j].Time < out[i].Date+out[i].Time })
	return out
}

// AddGateEvent appends an event unless one with that id already exists,
// mirroring Postgres' `ON CONFLICT (id) DO NOTHING`. The gate device records
// offline and pushes later, so a replayed push must not produce a second
// record — and the dev store has to behave as the production one does or the
// difference only shows up after deployment.
func (m *Memory) AddGateEvent(e domain.GateEvent) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, g := range m.gate {
		if g.ID == e.ID {
			return nil
		}
	}
	m.gate = append(m.gate, e)

	return nil
}

func (m *Memory) Questions() []domain.Question {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.questions
}

func (m *Memory) QuestionByID(id string) (domain.Question, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, q := range m.questions {
		if q.ID == id {
			return q, true
		}
	}
	return domain.Question{}, false
}

func (m *Memory) SaveQuestion(q domain.Question) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.questions = upsert(m.questions, q.ID, q)

	return nil
}

func (m *Memory) DeleteQuestion(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.questions = deleteByID(m.questions, id)

	return nil
}

func (m *Memory) AIRequests() []domain.GenRequest {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.aiRequests
}

func (m *Memory) AIRequestByID(id string) (domain.GenRequest, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, r := range m.aiRequests {
		if r.ID == id {
			return r, true
		}
	}
	return domain.GenRequest{}, false
}

func (m *Memory) SaveAIRequest(r domain.GenRequest) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.aiRequests = upsert(m.aiRequests, r.ID, r)

	return nil
}

func (m *Memory) Assessments() []domain.Assessment {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.assessments
}

func (m *Memory) AssessmentByID(id string) (domain.Assessment, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, a := range m.assessments {
		if a.ID == id {
			return a, true
		}
	}
	return domain.Assessment{}, false
}

func (m *Memory) SaveAssessment(a domain.Assessment) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.assessments = upsert(m.assessments, a.ID, a)

	return nil
}

func (m *Memory) Submissions() []domain.Submission {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.submissions
}

func (m *Memory) SubmissionFor(assessmentID, studentID string) (domain.Submission, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, s := range m.submissions {
		if s.AssessmentID == assessmentID && s.StudentID == studentID {
			return s, true
		}
	}
	return domain.Submission{}, false
}

func (m *Memory) SaveSubmission(s domain.Submission) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.submissions = removeMatch(m.submissions, s.AssessmentID, s.StudentID)
	m.submissions = append(m.submissions, s)

	return nil
}

func (m *Memory) Interventions() []domain.Intervention {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.interventions
}

func (m *Memory) InterventionByID(id string) (domain.Intervention, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, i := range m.interventions {
		if i.ID == id {
			return i, true
		}
	}
	return domain.Intervention{}, false
}

func (m *Memory) InterventionsForStudent(id string) []domain.Intervention {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []domain.Intervention
	for _, i := range m.interventions {
		if i.StudentID == id {
			out = append(out, i)
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[b].CreatedDate < out[a].CreatedDate })
	return out
}

func (m *Memory) SaveIntervention(i domain.Intervention) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.interventions = upsert(m.interventions, i.ID, i)

	return nil
}

func (m *Memory) Messages() []domain.Message {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.messages
}

func (m *Memory) SaveMessage(msg domain.Message) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.messages = append(m.messages, msg)

	return nil
}

func (m *Memory) Announcements() []domain.Announcement {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.announcements
}

func (m *Memory) AddAnnouncement(a domain.Announcement) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.announcements = append([]domain.Announcement{a}, m.announcements...)

	return nil
}

func (m *Memory) Notifications() []domain.Notification {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.notifications
}

func (m *Memory) SetNotificationRead(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i := range m.notifications {
		if m.notifications[i].ID == id {
			m.notifications[i].Read = true
			return nil
		}
	}

	return nil
}

func (m *Memory) AddNotification(n domain.Notification) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.notifications = append([]domain.Notification{n}, m.notifications...)
}

func (m *Memory) Assignments() []domain.Assignment {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.assignments
}

func (m *Memory) AssignmentByID(id string) (domain.Assignment, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, a := range m.assignments {
		if a.ID == id {
			return a, true
		}
	}
	return domain.Assignment{}, false
}

func (m *Memory) SaveAssignment(a domain.Assignment) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.assignments = upsert(m.assignments, a.ID, a)

	return nil
}

// todayString is the 'yyyy-MM-dd' the derived invoice status is judged
// against — the same zero-padded ISO format the client compares against.
func todayString() string { return time.Now().Format("2006-01-02") }

// Invoices returns every invoice with AmountPaid and Status already derived —
// the memory store mirrors what Postgres does by joining payments, so a test
// written against one store holds for the other.
func (m *Memory) Invoices() []domain.Invoice {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]domain.Invoice, 0, len(m.invoices))
	for _, inv := range m.invoices {
		out = append(out, inv.WithDerived(m.payments, todayString()))
	}
	return out
}

func (m *Memory) InvoiceByID(id string) (domain.Invoice, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, inv := range m.invoices {
		if inv.ID == id {
			return inv.WithDerived(m.payments, todayString()), true
		}
	}
	return domain.Invoice{}, false
}

// SaveInvoice upserts on the client-chosen id: an invoice's terms are edited,
// not minted, so a corrected version replaces the old one (and a replayed
// POST of the same invoice is a no-op).
func (m *Memory) SaveInvoice(inv domain.Invoice) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.invoices = upsert(m.invoices, inv.ID, inv)

	return nil
}

func (m *Memory) Payments() []domain.Payment {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.payments
}

// SavePayment skips a payment whose id is already recorded, mirroring
// Postgres' `ON CONFLICT (id) DO NOTHING`. The device firm-commits locally and
// replays through the outbox, so a replayed payment is the same collection
// seen twice — recording it again would pay the same money in twice, and the
// dev store must behave as the production one does or the difference only
// shows up after deployment.
func (m *Memory) SavePayment(p domain.Payment) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, x := range m.payments {
		if x.ID == p.ID {
			return nil
		}
	}
	m.payments = append(m.payments, p)

	return nil
}

func (m *Memory) AuditLogs() []domain.AuditEntry {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.audit
}

func (m *Memory) AddAudit(e domain.AuditEntry) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.audit = append(m.audit, e)
}

func (m *Memory) SaveRefreshToken(hash, userID string, expiresAt int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.refreshTokens == nil {
		m.refreshTokens = map[string]refreshRecord{}
	}
	m.refreshTokens[hash] = refreshRecord{UserID: userID, ExpiresAt: expiresAt}

	return nil
}

func (m *Memory) RefreshTokenLookup(hash string) (string, int64, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	rec, ok := m.refreshTokens[hash]
	return rec.UserID, rec.ExpiresAt, ok
}

func (m *Memory) DeleteRefreshToken(hash string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.refreshTokens, hash)

	return nil
}

func (m *Memory) DeleteRefreshTokensForUser(userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for h, rec := range m.refreshTokens {
		if rec.UserID == userID {
			delete(m.refreshTokens, h)
		}
	}

	return nil
}

// --- generic helpers ---

type keyed interface{ Key() string }

func upsert[T keyed](list []T, id string, item T) []T {
	out := make([]T, 0, len(list)+1)
	added := false
	for _, e := range list {
		if e.Key() == id {
			out = append(out, item)
			added = true
		} else {
			out = append(out, e)
		}
	}
	if !added {
		out = append(out, item)
	}
	return out
}

// deleteByID builds a fresh slice. Filtering in place with list[:0] would write
// into the store's own backing array while holding the write lock — but the
// getters hand that same array to callers after releasing the lock, so an
// in-place compaction races with any reader (detected by go test -race).
func deleteByID(list []domain.Question, id string) []domain.Question {
	if len(list) == 0 {
		return list
	}
	out := make([]domain.Question, 0, len(list))
	for _, q := range list {
		if q.ID != id {
			out = append(out, q)
		}
	}
	return out
}

// removeMatch is the same as deleteByID: a fresh slice, never list[:0], so the
// store's backing array is never written to while readers hold an alias.
func removeMatch(subs []domain.Submission, assessmentID, studentID string) []domain.Submission {
	if len(subs) == 0 {
		return subs
	}
	out := make([]domain.Submission, 0, len(subs))
	for _, s := range subs {
		if s.AssessmentID != assessmentID || s.StudentID != studentID {
			out = append(out, s)
		}
	}
	return out
}
