// Package domain holds the backend's data models. The JSON field names and
// enum string keys mirror the Flutter client's core/models exactly, so the
// mobile app and this API share one contract (camelCase JSON like the app's
// toJson(), enum values stored as their Dart enum .name strings).
package domain

import "encoding/json"

const (
	defaultSchoolID = "SCH-001"
)

// DefaultSchoolID returns the seed school id used when none is supplied.
func DefaultSchoolID() string { return defaultSchoolID }

// Role mirrors AppRole.key values.
const (
	RoleSuperAdmin   = "superAdmin"
	RoleSchoolAdmin  = "schoolAdmin"
	RoleHeadteacher  = "headteacher"
	RoleTeacher      = "teacher"
	RoleParent       = "parent"
	RoleStudent      = "student"
	RoleStaff        = "staff"
	RoleEduAuthority = "educationAuthority"
)

// AssessmentType mirrors AssessmentType.name values.
const (
	TypeExercise   = "exercise"
	TypeHomework   = "homework"
	TypeQuiz       = "quiz"
	TypeClassTest  = "classTest"
	TypeMidTerm    = "midTerm"
	TypeEndTerm    = "endTerm"
	TypeMock       = "mock"
	TypeDiagnostic = "diagnostic"
	TypeRemedial   = "remedial"
	TypeVacation   = "vacation"
)

// QuestionType mirrors QuestionType.name values.
const (
	QTypeMCQ         = "mcq"
	QTypeTrueFalse   = "trueFalse"
	QTypeFillBlank   = "fillBlank"
	QTypeShortAnswer = "shortAnswer"
	QTypeStructured  = "structured"
	QTypeMath        = "math"
	QTypeEssay       = "essay"
	QTypePractical   = "practical"
)

// AttendanceStatus mirrors AttendanceStatus.name values.
const (
	AttPresent = "present"
	AttLate    = "late"
	AttAbsent  = "absent"
	AttExcused = "excused"
)

// GateEventType mirrors GateEventType.name values.
const (
	GateArrival            = "arrival"
	GateDeparture          = "departure"
	GatePickupAuthorized   = "pickupAuthorized"
	GateUnauthorizedPickup = "unauthorizedPickup"
	GateEarlyDeparture     = "earlyDeparture"
)

// NotificationKind mirrors NotificationKind.name values.
const (
	NotifGate         = "gate"
	NotifAttendance   = "attendance"
	NotifAssessment   = "assessment"
	NotifMarking      = "marking"
	NotifIntervention = "intervention"
	NotifMessage      = "message"
	NotifAssignment   = "assignment"
	NotifAnnouncement = "announcement"
	NotifSystem       = "system"
)

// AnnouncementAudience mirrors AnnouncementAudience.name values.
const (
	AudSchool    = "school"
	AudClasses   = "classes"
	AudEmergency = "emergency"
)

// QGenStatus mirrors QGenStatus.name values.
const (
	QGenPending   = "pending"
	QGenGenerated = "generated"
	QGenPublished = "published"
	QGenRejected  = "rejected"
)

// InterventionStatus mirrors InterventionStatus.name values.
const (
	IntOpen       = "open"
	IntInProgress = "inProgress"
	IntCompleted  = "completed"
	IntCancelled  = "cancelled"
)

// User mirrors the client User model (doc §9).
type User struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Email      string   `json:"email"`
	Phone      string   `json:"phone"`
	Password   string   `json:"-"`
	Role       string   `json:"role"`
	SchoolID   string   `json:"schoolId,omitempty"`
	ClassID    string   `json:"classId,omitempty"`
	StudentIDs []string `json:"studentIds"`
	// TokenVersion is bumped on password change / full sign-out; access
	// tokens carrying an older version are refused (session revocation).
	TokenVersion int `json:"-"`
}

func (u User) IsSchoolStaff() bool {
	switch u.Role {
	case RoleSuperAdmin, RoleSchoolAdmin, RoleHeadteacher, RoleTeacher, RoleStaff:
		return true
	}
	return false
}

func (u User) IsSchoolLeader() bool {
	return u.Role == RoleSchoolAdmin || u.Role == RoleHeadteacher
}

func (u User) IsSuperAdmin() bool { return u.Role == RoleSuperAdmin }

// Person mirrors the client Person model.
type Person struct {
	Name     string `json:"name"`
	Phone    string `json:"phone"`
	Relation string `json:"relation"`
}

// Student mirrors the client Student model (doc §10).
type Student struct {
	ID                string   `json:"id"`
	FirstName         string   `json:"firstName"`
	LastName          string   `json:"lastName"`
	Gender            string   `json:"gender"`
	DateOfBirth       string   `json:"dateOfBirth"`
	AdmissionDate     string   `json:"admissionDate"`
	AdmissionNo       string   `json:"admissionNo"`
	ClassID           string   `json:"classId"`
	SchoolID          string   `json:"schoolId"`
	Status            string   `json:"status"`
	ParentUserID      string   `json:"parentUserId,omitempty"`
	Guardians         []Person `json:"guardians"`
	EmergencyContacts []Person `json:"emergencyContacts"`
	AuthorizedPickup  []Person `json:"authorizedPickup"`
}

func (s Student) FullName() string { return s.FirstName + " " + s.LastName }

// PromotedToClass returns the next JHS class or "".
func (s Student) PromotedToClass() string {
	order := []string{"JHS1A", "JHS1B", "JHS2A", "JHS2B", "JHS3A", "JHS3B"}
	for i, c := range order {
		if c == s.ClassID {
			if i < len(order)-1 {
				return order[i+1]
			}
		}
	}
	return ""
}

// ClassRoom mirrors the client ClassRoom model.
type ClassRoom struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Stream    string `json:"stream"`
	TeacherID string `json:"teacherId,omitempty"`
}

// School mirrors the client School model.
type School struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Motto   string `json:"motto"`
	Address string `json:"address"`
	Phone   string `json:"phone"`
	Email   string `json:"email"`
	Region  string `json:"region"`
}

// SchoolTerm mirrors the client SchoolTerm model (doc §7, §19).
type SchoolTerm struct {
	Year  string `json:"year"`
	Name  string `json:"name"`
	Start string `json:"start"`
	End   string `json:"end"`
}

func (t SchoolTerm) Label() string { return t.Name + " · " + t.Year }

func (t SchoolTerm) Contains(date string) bool {
	return date >= t.Start && date <= t.End
}

// AttendanceRecord mirrors the client AttendanceRecord model (doc §12).
type AttendanceRecord struct {
	ID        string `json:"id"`
	StudentID string `json:"studentId"`
	ClassID   string `json:"classId"`
	Date      string `json:"date"`
	Status    string `json:"status"`
	CheckIn   string `json:"checkIn,omitempty"`
	CheckOut  string `json:"checkOut,omitempty"`
	OldStatus string `json:"oldStatus,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

// AttendanceDay groups one class's records for one date.
type AttendanceDay struct {
	Date     string             `json:"date"`
	ClassID  string             `json:"classId"`
	MarkedBy string             `json:"markedBy"`
	Records  []AttendanceRecord `json:"records"`
}

// AttendanceSummary mirrors AttendanceRepository.summaryForStudent.
type AttendanceSummary struct {
	StudentID  string  `json:"studentId"`
	Present    int     `json:"present"`
	Late       int     `json:"late"`
	Absent     int     `json:"absent"`
	Excused    int     `json:"excused"`
	TotalDays  int     `json:"totalDays"`
	Percentage float64 `json:"percentage"`
}

// GateEvent mirrors the client GateEvent model (doc §13).
type GateEvent struct {
	ID        string `json:"id"`
	StudentID string `json:"studentId"`
	Type      string `json:"type"`
	Time      string `json:"time"`
	Date      string `json:"date"`
	Reporter  string `json:"reporter"`
	Person    string `json:"person,omitempty"`
	Detail    string `json:"detail"`
}

// Question mirrors the client Question model (doc §17).
type Question struct {
	ID             string   `json:"id"`
	Type           string   `json:"type"`
	SubjectID      string   `json:"subjectId"`
	ClassID        string   `json:"classId"`
	Topic          string   `json:"topic"`
	Difficulty     int      `json:"difficulty"`
	CognitiveLevel string   `json:"cognitiveLevel"`
	Marks          float64  `json:"marks"`
	Stem           string   `json:"stem"`
	Options        []string `json:"options"`
	CorrectAnswer  string   `json:"correctAnswer"`
	Explanation    string   `json:"explanation"`
	MarkingScheme  string   `json:"markingScheme"`
}

func (q Question) IsObjective() bool {
	return q.Type == QTypeMCQ || q.Type == QTypeTrueFalse
}

// Assessment mirrors the client Assessment model (doc §16).
type Assessment struct {
	ID        string     `json:"id"`
	Title     string     `json:"title"`
	Type      string     `json:"type"`
	SubjectID string     `json:"subjectId"`
	ClassID   string     `json:"classId"`
	Date      string     `json:"date"`
	CreatedBy string     `json:"createdBy"`
	Questions []Question `json:"questions"`
}

func (a Assessment) TotalMarks() (m float64) {
	for _, q := range a.Questions {
		m += q.Marks
	}
	return m
}

// Submission mirrors the client AssessmentSubmission model.
type Submission struct {
	ID                   string             `json:"id"`
	AssessmentID         string             `json:"assessmentId"`
	StudentID            string             `json:"studentId"`
	ClassID              string             `json:"classId"`
	Date                 string             `json:"date"`
	Answers              map[string]string  `json:"answers"`
	TeacherMarks         map[string]float64 `json:"teacherMarks"`
	Earned               float64            `json:"earned"`
	MarkingSchemeID      string             `json:"markingSchemeId,omitempty"`
	MarkingSchemeVersion int                `json:"markingSchemeVersion,omitempty"`
}

// Intervention mirrors the client Intervention model (doc §31).
type Intervention struct {
	ID                       string `json:"id"`
	StudentID                string `json:"studentId"`
	Topic                    string `json:"topic"`
	Action                   string `json:"action"`
	AssignedBy               string `json:"assignedBy"`
	CreatedDate              string `json:"createdDate"`
	Status                   string `json:"status"`
	ReassessmentAssessmentID string `json:"reassessmentAssessmentId,omitempty"`
}

// Message mirrors the client Message model (doc §40).
type Message struct {
	ID               string `json:"id"`
	FromID           string `json:"fromId"`
	ToID             string `json:"toId"`
	RelatedStudentID string `json:"relatedStudentId,omitempty"`
	Subject          string `json:"subject"`
	Body             string `json:"body"`
	Timestamp        string `json:"timestamp"`
	Read             bool   `json:"read"`
	// Delivery receipts the recipient's device reports back: delivered when
	// their inbox loaded the message, read when they opened the thread.
	DeliveredAt string `json:"deliveredAt,omitempty"`
	ReadAt      string `json:"readAt,omitempty"`
	// State is derived for the client (sent → delivered → read), never stored.
	State string `json:"state,omitempty"`
}

// Announcement mirrors the client Announcement model (doc §40).
type Announcement struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	Body          string `json:"body"`
	Audience      string `json:"audience"`
	TargetClassID string `json:"targetClassId,omitempty"`
	AuthorID      string `json:"authorId"`
	AuthorName    string `json:"authorName"`
	Timestamp     string `json:"timestamp"`
}

// Notification mirrors the client AppNotification model (doc §36, §40).
type Notification struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Timestamp string `json:"timestamp"`
	StudentID string `json:"studentId,omitempty"`
	UserID    string `json:"userId,omitempty"`
	Read      bool   `json:"read"`
}

// Assignment mirrors the client Assignment model (doc §41).
type Assignment struct {
	ID           string   `json:"id"`
	ClassID      string   `json:"classId"`
	SubjectID    string   `json:"subjectId"`
	Title        string   `json:"title"`
	Instructions string   `json:"instructions"`
	Deadline     string   `json:"deadline"`
	CreatedBy    string   `json:"createdBy"`
	CreatedAt    string   `json:"createdAt"`
	CompletedBy  []string `json:"completedBy"`
}

// AuditEntry mirrors the client AuditEntry model (doc §49).
type AuditEntry struct {
	ID        string `json:"id"`
	Action    string `json:"action"`
	Actor     string `json:"actor"`
	Target    string `json:"target"`
	Detail    string `json:"detail"`
	Timestamp string `json:"timestamp"`
	Reason    string `json:"reason,omitempty"`
}

// GenRequest mirrors the client QuestionGenRequest model (doc §43).
type GenRequest struct {
	ID            string     `json:"id"`
	RequesterID   string     `json:"requesterId"`
	RequesterName string     `json:"requesterName"`
	SubjectID     string     `json:"subjectId"`
	Topic         string     `json:"topic"`
	Type          string     `json:"type"`
	Count         int        `json:"count"`
	Priority      string     `json:"priority"`
	ClassID       string     `json:"classId"`
	CreatedAt     string     `json:"createdAt"`
	PublishedAt   string     `json:"publishedAt,omitempty"`
	Status        string     `json:"status"`
	Drafts        []Question `json:"drafts"`
}

// ScanJob is the paper-scan → background-job record (doc §20, §54).
type ScanJob struct {
	ID           string `json:"id"`
	AssessmentID string `json:"assessmentId"`
	StudentID    string `json:"studentId"`
	Status       string `json:"status"` // queued | processing | ready | retake_needed
	Pages        int    `json:"pages"`
	CreatedAt    string `json:"createdAt"`
}

// Subjects is the fixed curriculum list shared with the app.
var Subjects = []struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}{
	{"MATH", "Mathematics"},
	{"ENG", "English Language"},
	{"SCI", "Integrated Science"},
	{"SOC", "Social Studies"},
	{"ICT", "Information & Communication Technology"},
	{"RME", "Religious & Moral Education"},
}

// SubjectName resolves a subject id to its display name, mirroring subjectName().
func SubjectName(id string) string {
	for _, s := range Subjects {
		if s.ID == id {
			return s.Name
		}
	}
	return id
}

// Payment mirrors the client's fees Payment (lib/features/fees): one money
// movement against an invoice, firm-committed on the device first and replayed
// to POST /api/payments through the sync outbox. The client picks `id`, so the
// write has to be idempotent — a replay of the same payment must be a no-op or
// one collection is recorded twice.
type Payment struct {
	ID        string `json:"id"`
	InvoiceID string `json:"invoiceId"`
	// Student the payment is for, so reads can be scoped per student without
	// resolving the invoice first. Nullable in storage and omitted from the
	// wire when empty: a client that predates it still sends a payment we
	// must record, not reject.
	StudentID  string `json:"studentId,omitempty"`
	Amount     int    `json:"amount"` // GHS, whole units as the app sends them
	Method     string `json:"method"` // cash | card | mobileMoney | bank
	Reference  string `json:"reference,omitempty"`
	PaidAt     string `json:"paidAt"` // 'yyyy-MM-dd HH:mm', as the receipt renders it
	RecordedBy string `json:"recordedBy"`
}

// FeeLineItem mirrors the client FeeLineItem: one charge on an invoice.
type FeeLineItem struct {
	Name   string `json:"name"`
	Amount int    `json:"amount"` // GHS
}

// Invoice status keys, mirroring the client's InvoiceStatus enum.
const (
	InvoiceStatusDue     = "due"
	InvoiceStatusPartial = "partial"
	InvoiceStatusOverdue = "overdue"
	InvoiceStatusPaid    = "paid"
)

// Invoice mirrors the client's fees Invoice (lib/features/fees).
//
// AmountPaid and Status are part of the wire contract — the client serialises
// both — but they are DERIVED on read and never read back from storage: the
// sum comes from the payments table and the status from ResolveStatus, so a
// payment recorded on a second device is reflected immediately instead of
// being masked by the snapshot written when the invoice was created.
type Invoice struct {
	ID         string        `json:"id"`
	StudentID  string        `json:"studentId"`
	IssueDate  string        `json:"issueDate"` // 'yyyy-MM-dd'
	DueDate    string        `json:"dueDate"`   // 'yyyy-MM-dd'
	LineItems  []FeeLineItem `json:"lineItems"`
	Term       string        `json:"term"`
	AmountPaid int           `json:"amountPaid"` // derived: SUM of payments
	Status     string        `json:"status"`     // derived: see ResolveStatus
}

// Total is the sum of the line items (GHS), mirroring Invoice.total.
func (i Invoice) Total() int {
	total := 0
	for _, item := range i.LineItems {
		total += item.Amount
	}
	return total
}

// Balance is what is still owed, never negative (GHS).
func (i Invoice) Balance() int {
	if b := i.Total() - i.AmountPaid; b > 0 {
		return b
	}
	return 0
}

// ResolveStatus mirrors the client's Invoice.resolveStatus: settled → paid;
// past the due date with a balance → overdue; part-paid → partial; otherwise
// due. `today` is 'yyyy-MM-dd', and since every date involved is a
// zero-padded ISO date, comparing the strings is the same ordering the client
// gets by parsing both sides.
func (i Invoice) ResolveStatus(today string) string {
	if i.Balance() <= 0 {
		return InvoiceStatusPaid
	}
	if i.DueDate != "" && today > i.DueDate {
		return InvoiceStatusOverdue
	}
	if i.AmountPaid > 0 {
		return InvoiceStatusPartial
	}
	return InvoiceStatusDue
}

// WithDerived returns the invoice as the read side serves it: AmountPaid
// summed from every payment against this invoice, Status resolved from the
// dates. Storing either would let a payment recorded on a second device be
// masked by the snapshot written at creation time, so neither is ever read
// back from storage.
func (i Invoice) WithDerived(payments []Payment, today string) Invoice {
	paid := 0
	for _, p := range payments {
		if p.InvoiceID == i.ID {
			paid += p.Amount
		}
	}
	i.AmountPaid = paid
	i.Status = i.ResolveStatus(today)
	return i
}

// Key returns the primary identifier; used by the store layer upsert helper.
func (i Invoice) Key() string { return i.ID }

// Key returns the primary identifier; used by the store layer upsert helper.
func (u User) Key() string            { return u.ID }
func (c ClassRoom) Key() string       { return c.ID }
func (s Student) Key() string         { return s.ID }
func (q Question) Key() string        { return q.ID }
func (r GenRequest) Key() string      { return r.ID }
func (a Assessment) Key() string      { return a.ID }
func (i Intervention) Key() string    { return i.ID }
func (a Assignment) Key() string      { return a.ID }
func (ms MarkingScheme) Key() string  { return ms.ID }
func (sq SchemeQuestion) Key() string { return sq.ID }
func (sp ScanPage) Key() string       { return sp.ID }

// Record kinds the server stores (see Record).
const (
	RecordLessons           = "lessons"
	RecordResources         = "resources"
	RecordSafetyCompletions = "safety_completions"
	RecordCorrections       = "corrections"
	RecordTargets           = "targets"
	RecordScans             = "scans"
	// RecordAssignmentSubmissions holds a teacher's captured submission of one
	// student's assignment work: one record per submission, carrying any
	// number of photographed pages. Scoped like RecordScans (student-scoped
	// reads, staff may write) so a submission about a pupil stays inside the
	// same visibility boundary.
	RecordAssignmentSubmissions = "assignment_submissions"
	// RecordOcrJobs holds one page handed to the OCR pipeline together with
	// what the engine read from it and the teacher's confirmation of that
	// reading.
	//
	// Owner-scoped rather than student-scoped: the row is written about
	// work, not about a named pupil, and scoping it by student would make a
	// job with no studentId invisible to the very teacher who created it.
	// scopeOwner sets OwnerID on the server from the session, so a client
	// cannot claim another teacher's reading, and the same teacher picks the
	// job up on any device they sign in from.
	RecordOcrJobs = "ocr_jobs"
)

// Record is one entry of a collection the server stores on the client's
// behalf without modelling it (timetable slots, resources, training
// completions, corrections, targets, scan pages). Data is the client's own
// JSON; StudentID, ClassID and OwnerID are lifted out of it so reads can be
// scoped like the modelled collections.
type Record struct {
	Kind      string          `json:"-"`
	ID        string          `json:"-"`
	StudentID string          `json:"-"`
	ClassID   string          `json:"-"`
	OwnerID   string          `json:"-"`
	UpdatedAt string          `json:"-"`
	Data      json.RawMessage `json:"-"`
}
