// Package store provides persistence for the backend. A Store interface keeps
// the API layer independent of storage so later swaps to PostgreSQL (see
// migrations/) only need a new implementation. The shipped implementation is
// in-memory and is seeded with the same data the Flutter app generates
// locally, so the API is instantly runnable for development.
package store

import (
	"sort"
	"strings"
	"sync"

	"solvanta/backend/internal/domain"
)

// Store is the persistence contract used by the API handlers.
type Store interface {
	// School & term
	School() domain.School
	SaveSchool(s domain.School)
	Term() domain.SchoolTerm
	SaveTerm(t domain.SchoolTerm)

	// Users (doc §9)
	Users() []domain.User
	UserByID(id string) (domain.User, bool)
	UserByEmail(email string) (domain.User, bool)
	SaveUser(u domain.User)

	// Classes
	Classes() []domain.ClassRoom
	ClassByID(id string) (domain.ClassRoom, bool)
	SaveClass(c domain.ClassRoom)

	// Students (doc §10)
	Students() []domain.Student
	StudentByID(id string) (domain.Student, bool)
	StudentsByParentUser(id string) []domain.Student
	SaveStudent(s domain.Student)

	// Attendance (doc §12)
	Attendance() []domain.AttendanceRecord
	AttendanceForClassDate(classID, date string) []domain.AttendanceRecord
	SaveAttendance(records []domain.AttendanceRecord)                // replace whole log (bootstrap/import)
	SaveDay(classID, date string, records []domain.AttendanceRecord) // replace one day

	// Gate (doc §13)
	GateEvents() []domain.GateEvent
	GateForStudent(id string) []domain.GateEvent
	AddGateEvent(e domain.GateEvent)

	// Questions + AI generation (doc §17, §43)
	Questions() []domain.Question
	QuestionByID(id string) (domain.Question, bool)
	SaveQuestion(q domain.Question)
	DeleteQuestion(id string)
	AIRequests() []domain.GenRequest
	AIRequestByID(id string) (domain.GenRequest, bool)
	SaveAIRequest(r domain.GenRequest)

	// Assessments (doc §16)
	Assessments() []domain.Assessment
	AssessmentByID(id string) (domain.Assessment, bool)
	SaveAssessment(a domain.Assessment)

	// Submissions (doc §26)
	Submissions() []domain.Submission
	SubmissionFor(assessmentID, studentID string) (domain.Submission, bool)
	SaveSubmission(s domain.Submission)

	// Interventions (doc §31)
	Interventions() []domain.Intervention
	InterventionByID(id string) (domain.Intervention, bool)
	InterventionsForStudent(id string) []domain.Intervention
	SaveIntervention(i domain.Intervention)

	// Communication (doc §40)
	Messages() []domain.Message
	SaveMessage(m domain.Message)
	Announcements() []domain.Announcement
	AddAnnouncement(a domain.Announcement)
	Notifications() []domain.Notification
	AddNotification(n domain.Notification)
	SetNotificationRead(id string)

	// Assignments (doc §41)
	Assignments() []domain.Assignment
	AssignmentByID(id string) (domain.Assignment, bool)
	SaveAssignment(a domain.Assignment)

	// Audit (doc §49)
	AuditLogs() []domain.AuditEntry
	AddAudit(e domain.AuditEntry)

	// Refresh-token sessions (auth state, opaque + stored hashed)
	SaveRefreshToken(hash, userID string, expiresAt int64)
	RefreshTokenLookup(hash string) (userID string, expiresAt int64, ok bool)
	DeleteRefreshToken(hash string)
	DeleteRefreshTokensForUser(userID string)
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
	audit         []domain.AuditEntry
	refreshTokens map[string]refreshRecord
}

type refreshRecord struct {
	UserID    string
	ExpiresAt int64
}

// New returns a fresh in-memory store, seeded with development data.
func New() *Memory {
	m := &Memory{}
	m.seed()
	return m
}

func (m *Memory) School() domain.School {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.school
}

func (m *Memory) SaveSchool(s domain.School) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.school = s
}

func (m *Memory) Term() domain.SchoolTerm {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.term
}

func (m *Memory) SaveTerm(t domain.SchoolTerm) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.term = t
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

func (m *Memory) SaveUser(u domain.User) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.users = upsert(m.users, u.ID, u)
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

func (m *Memory) SaveClass(c domain.ClassRoom) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.classes = upsert(m.classes, c.ID, c)
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

func (m *Memory) SaveStudent(s domain.Student) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.students = upsert(m.students, s.ID, s)
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

func (m *Memory) SaveAttendance(records []domain.AttendanceRecord) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.attendance = records
}

func (m *Memory) SaveDay(classID, date string, records []domain.AttendanceRecord) {
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

func (m *Memory) AddGateEvent(e domain.GateEvent) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gate = append(m.gate, e)
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

func (m *Memory) SaveQuestion(q domain.Question) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.questions = upsert(m.questions, q.ID, q)
}

func (m *Memory) DeleteQuestion(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.questions = deleteByID(m.questions, id)
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

func (m *Memory) SaveAIRequest(r domain.GenRequest) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.aiRequests = upsert(m.aiRequests, r.ID, r)
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

func (m *Memory) SaveAssessment(a domain.Assessment) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.assessments = upsert(m.assessments, a.ID, a)
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

func (m *Memory) SaveSubmission(s domain.Submission) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.submissions = removeMatch(m.submissions, s.AssessmentID, s.StudentID)
	m.submissions = append(m.submissions, s)
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

func (m *Memory) SaveIntervention(i domain.Intervention) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.interventions = upsert(m.interventions, i.ID, i)
}

func (m *Memory) Messages() []domain.Message {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.messages
}

func (m *Memory) SaveMessage(msg domain.Message) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.messages = append(m.messages, msg)
}

func (m *Memory) Announcements() []domain.Announcement {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.announcements
}

func (m *Memory) AddAnnouncement(a domain.Announcement) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.announcements = append([]domain.Announcement{a}, m.announcements...)
}

func (m *Memory) Notifications() []domain.Notification {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.notifications
}

func (m *Memory) SetNotificationRead(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i := range m.notifications {
		if m.notifications[i].ID == id {
			m.notifications[i].Read = true
			return
		}
	}
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

func (m *Memory) SaveAssignment(a domain.Assignment) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.assignments = upsert(m.assignments, a.ID, a)
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

func (m *Memory) SaveRefreshToken(hash, userID string, expiresAt int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.refreshTokens == nil {
		m.refreshTokens = map[string]refreshRecord{}
	}
	m.refreshTokens[hash] = refreshRecord{UserID: userID, ExpiresAt: expiresAt}
}

func (m *Memory) RefreshTokenLookup(hash string) (string, int64, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	rec, ok := m.refreshTokens[hash]
	return rec.UserID, rec.ExpiresAt, ok
}

func (m *Memory) DeleteRefreshToken(hash string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.refreshTokens, hash)
}

func (m *Memory) DeleteRefreshTokensForUser(userID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for h, rec := range m.refreshTokens {
		if rec.UserID == userID {
			delete(m.refreshTokens, h)
		}
	}
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

func deleteByID(list []domain.Question, id string) []domain.Question {
	out := list[:0]
	for _, q := range list {
		if q.ID != id {
			out = append(out, q)
		}
	}
	return out
}

func removeMatch(subs []domain.Submission, assessmentID, studentID string) []domain.Submission {
	out := subs[:0]
	for _, s := range subs {
		if s.AssessmentID != assessmentID || s.StudentID != studentID {
			out = append(out, s)
		}
	}
	return out
}
