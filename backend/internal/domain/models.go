// Package domain holds the backend's data models. The JSON field names and
// enum string keys mirror the Flutter client's core/models exactly, so the
// mobile app and this API share one contract (camelCase JSON like the app's
// toJson(), enum values stored as their Dart enum .name strings).
package domain

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
)

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

// MarkingMode mirrors MarkingMode.name values: a school-level setting that
// decides whether scores come from AI/OCR marking, from manual entry, or both.
// An empty stored value means the default, Both (see School.EffectiveMarkingMode).
const (
	MarkingModeAI     = "ai"
	MarkingModeManual = "manual"
	MarkingModeBoth   = "both"
)

// SubmissionSource mirrors SubmissionSource.name values: where a submission's
// score came from. An empty stored value is treated as the historical default,
// Online (a question-by-question submission); AI is a finalized marking draft,
// Manual a score recorded by hand.
const (
	SourceAI     = "ai"
	SourceManual = "manual"
	SourceOnline = "online"
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
	NotifReportCard   = "reportCard"
	NotifMeeting      = "meeting"
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
	// MFASecret is the user's TOTP secret (base32); MFAEnabled is set once they
	// confirm a code. Both are server-only — never serialised to any client.
	MFASecret  string `json:"-"`
	MFAEnabled bool   `json:"-"`
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

// SchoolKind mirrors SchoolKind.name: a normal school, or an independent
// teacher's own workspace (a tenant owned by one teacher, with a reduced
// feature set). Empty means the default, `school`.
const (
	SchoolKindSchool      = "school"
	SchoolKindIndependent = "independent"
)

// School mirrors the client School model.
type School struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Motto   string `json:"motto"`
	Address string `json:"address"`
	Phone   string `json:"phone"`
	Email   string `json:"email"`
	Region  string `json:"region"`
	// MarkingMode decides how this school records scores: ai, manual or both.
	// Empty means the default (both); read it through EffectiveMarkingMode so
	// an un-set school is never silently locked out of either path.
	MarkingMode string `json:"markingMode,omitempty"`
	// Kind is `school` (default) or `independent`. An independent workspace is
	// owned by OwnerUserID (the teacher who registered it) and may use only the
	// features SchoolAllows lets it.
	Kind        string `json:"kind,omitempty"`
	OwnerUserID string `json:"ownerUserId,omitempty"`
	// DataProtectionAcceptedAt records when the independent teacher accepted the
	// data-protection notice at registration (empty for normal schools).
	DataProtectionAcceptedAt string `json:"dataProtectionAcceptedAt,omitempty"`
	// Archived marks a workspace that has been transferred into a school and is
	// now read-only; writes to it are refused.
	Archived bool `json:"archived,omitempty"`
}

// EffectiveKind returns the school's kind, defaulting an empty value to School.
func (s School) EffectiveKind() string {
	if s.Kind == SchoolKindIndependent {
		return SchoolKindIndependent
	}
	return SchoolKindSchool
}

// IsIndependent reports an independent teacher's workspace.
func (s School) IsIndependent() bool { return s.EffectiveKind() == SchoolKindIndependent }

// EffectiveMarkingMode returns the school's marking mode, defaulting to Both
// when none has been chosen. Handlers gate on this, never on the raw field.
func (s School) EffectiveMarkingMode() string {
	switch s.MarkingMode {
	case MarkingModeAI, MarkingModeManual, MarkingModeBoth:
		return s.MarkingMode
	default:
		return MarkingModeBoth
	}
}

// AllowsAIMarking reports whether the school's mode permits the AI/OCR marking
// path (ai or both). In manual mode the AI entry points are closed.
func (s School) AllowsAIMarking() bool {
	return s.EffectiveMarkingMode() != MarkingModeManual
}

// AllowsManualScores reports whether the school's mode permits recording a
// score by hand (manual or both). In ai mode manual entry is closed.
func (s School) AllowsManualScores() bool {
	return s.EffectiveMarkingMode() != MarkingModeAI
}

// SchoolTerm mirrors the client SchoolTerm model (doc §7, §19).
type SchoolTerm struct {
	Year  string `json:"year"`
	Name  string `json:"name"`
	Start string `json:"start"`
	End   string `json:"end"`
	// NextStart is when school reopens for the next term, once announced.
	NextStart string `json:"nextStart,omitempty"`
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
//
// MaxScore supports "score-only" assessments — ones a school marks on paper and
// only records a final mark for, with no questions. When it is set the paper's
// effective total is MaxScore; otherwise it is the sum of the question marks.
// Read the total through EffectiveTotal, never TotalMarks directly, so a
// score-only paper is never treated as being out of 0.
type Assessment struct {
	ID        string     `json:"id"`
	Title     string     `json:"title"`
	Type      string     `json:"type"`
	SubjectID string     `json:"subjectId"`
	ClassID   string     `json:"classId"`
	Date      string     `json:"date"`
	CreatedBy string     `json:"createdBy"`
	Questions []Question `json:"questions"`
	// MaxScore is the explicit total for a score-only assessment. Nullable: a
	// nil pointer means "derive from the questions", a set one wins.
	MaxScore *float64 `json:"maxScore,omitempty"`
}

// TotalMarks is the sum of the question marks (0 when there are no questions).
func (a Assessment) TotalMarks() (m float64) {
	for _, q := range a.Questions {
		m += q.Marks
	}
	return m
}

// EffectiveTotal is the mark the paper is out of: MaxScore when one is set,
// otherwise the sum of the question marks. Every grade, percentage and average
// is computed against this.
func (a Assessment) EffectiveTotal() float64 {
	if a.MaxScore != nil {
		return *a.MaxScore
	}
	return a.TotalMarks()
}

// IsScoreOnly reports a paper created with an explicit max score and no
// questions — marked on paper, only the final mark recorded.
func (a Assessment) IsScoreOnly() bool {
	return a.MaxScore != nil && len(a.Questions) == 0
}

// Submission mirrors the client AssessmentSubmission model.
//
// Source records where the score came from: online (a question-by-question
// submission, the historical default and the empty value), ai (a finalized
// marking draft) or manual (a score recorded by hand). A manual submission has
// Earned set and empty Answers. Absent marks a pupil who did not sit the paper
// — not the same as a zero, and excluded from averages — and Remark is an
// optional per-score note.
type Submission struct {
	ID                   string             `json:"id"`
	AssessmentID         string             `json:"assessmentId"`
	StudentID            string             `json:"studentId"`
	ClassID              string             `json:"classId"`
	Date                 string             `json:"date"`
	Answers              map[string]string  `json:"answers"`
	TeacherMarks         map[string]float64 `json:"teacherMarks"`
	Earned               float64            `json:"earned"`
	Source               string             `json:"source,omitempty"`
	Remark               string             `json:"remark,omitempty"`
	Absent               bool               `json:"absent"`
	MarkingSchemeID      string             `json:"markingSchemeId,omitempty"`
	MarkingSchemeVersion int                `json:"markingSchemeVersion,omitempty"`
}

// EffectiveSource returns the submission's source, defaulting an empty stored
// value to Online — the historical behaviour before scores had a source.
func (s Submission) EffectiveSource() string {
	if s.Source == "" {
		return SourceOnline
	}
	return s.Source
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
	// Hash chains this entry to the previous one (see AuditChainHash), making
	// the log tamper-evident: altering or dropping any entry breaks the chain
	// from that point on, which VerifyAuditChain detects.
	Hash string `json:"hash,omitempty"`
}

// AuditChainHash is the hash of an entry folded onto the previous entry's hash.
// The row id is deliberately excluded (the database assigns it on insert, so it
// is not known when hashing), which does not weaken tamper-evidence: the
// content and ordering are what the chain protects.
func AuditChainHash(prev string, e AuditEntry) string {
	h := sha256.New()
	for _, part := range []string{prev, e.Action, e.Actor, e.Target, e.Detail, e.Timestamp, e.Reason} {
		h.Write([]byte(part))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// VerifyAuditChain recomputes the chain over entries (in recorded order) and
// returns whether it is intact, and the index of the first broken link (or -1).
func VerifyAuditChain(entries []AuditEntry) (ok bool, brokenAt int) {
	prev := ""
	for i, e := range entries {
		if e.Hash != AuditChainHash(prev, e) {
			return false, i
		}
		prev = e.Hash
	}
	return true, -1
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
	// OCRResult is what the recogniser read for this request, kept so a
	// reading whose response was lost can be fetched again. Raw JSON so the
	// domain does not depend on the ocr package; never marked confirmed.
	OCRResult json.RawMessage `json:"ocrResult,omitempty"`
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
	// The rest of the Ghanaian basic-school (KG–JHS) curriculum.
	{"FRE", "French"},
	{"GHL", "Ghanaian Language"},
	{"CAD", "Creative Arts & Design"},
	{"CTE", "Career Technology"},
	{"PHE", "Physical & Health Education"},
	{"OWOP", "Our World Our People"},
	{"HIS", "History"},
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
	// RecordPromotions holds the end-of-year decision applied to one student
	// for one academic year (promoted / repeated / completed), keyed by year
	// and student so a year can never be applied twice. Student-scoped so
	// parents see their own child's; only school leaders write it.
	RecordPromotions = "promotions"
	// RecordTermReports holds one student's report for one term: the class
	// teacher's remark and conduct/attitude/interest, the headteacher's
	// remark, and — once approved — a frozen copy of the whole card. See
	// httpapi/term_reports.go for who may write which part.
	RecordTermReports = "term_reports"
	// RecordPushTokens holds a user's registered device push tokens (one record
	// per device, owner-scoped). Remote notifications fan out to these.
	RecordPushTokens = "push_tokens"
	// RecordParentMeetings follows up a report card's "parent meeting
	// requested": requested → scheduled (date, place; the family is told) →
	// held (what was agreed) or cancelled. Staff write; families read their
	// own child's.
	RecordParentMeetings = "parent_meetings"
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
