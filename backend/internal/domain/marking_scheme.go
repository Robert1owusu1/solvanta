// Package domain holds the backend's data models. The JSON field names and
// enum string keys mirror the Flutter client's core/models exactly, so the
// mobile app and this API share one contract (camelCase JSON like the app's
// toJson(), enum values stored as their Dart enum .name strings).
package domain

// MarkingScheme mirrors the structured grading template for an assessment or assignment.
type MarkingScheme struct {
	ID             string           `json:"id"`
	AssessmentID   string           `json:"assessmentId,omitempty"`
	AssignmentID   string           `json:"assignmentId,omitempty"`
	Version        int              `json:"version"`
	ParentSchemeID string           `json:"parentSchemeId,omitempty"`
	CreatedBy      string           `json:"createdBy"`
	CreatedAt      string           `json:"createdAt"`
	Questions      []SchemeQuestion `json:"questions,omitempty"`
}

// SchemeQuestion is one question in the marking scheme.
type SchemeQuestion struct {
	ID              string              `json:"id"`
	SchemeID        string              `json:"schemeId"`
	QuestionNumber  int                 `json:"questionNumber"`
	TotalMarks      float64             `json:"totalMarks"`
	MarkBreakdown   []MarkBreakdownStep `json:"markBreakdown"`
	AcceptedAnswers []AcceptedAnswer    `json:"acceptedAnswers"`
	Misconceptions  []Misconception     `json:"misconceptions"`
	CreatedAt       string              `json:"createdAt"`
}

// MarkBreakdownStep is one partial-credit step in a question's mark breakdown.
type MarkBreakdownStep struct {
	ID       string  `json:"id"`   // stable key: "step-1", "step-2"
	Type     string  `json:"type"` // "method" | "final_answer" | "working" | "other"
	Criteria string  `json:"criteria"`
	Marks    float64 `json:"marks"`
}

// AcceptedAnswer is one valid answer variant for a scheme question.
type AcceptedAnswer struct {
	ID               int64   `json:"id"`
	SchemeQuestionID string  `json:"schemeQuestionId"`
	AnswerText       string  `json:"answerText"`
	NormalizedForm   string  `json:"normalizedForm"`
	MarksAwarded     float64 `json:"marksAwarded"`
	IsPrimary        bool    `json:"isPrimary"`
	CreatedAt        string  `json:"createdAt"`
}

// Misconception is a common wrong-answer pattern with likely cause.
type Misconception struct {
	ID                 int64   `json:"id"`
	SchemeQuestionID   string  `json:"schemeQuestionId"`
	WrongAnswerPattern string  `json:"wrongAnswerPattern"`
	LikelyCause        string  `json:"likelyCause"`
	MarksAwarded       float64 `json:"marksAwarded"`
	CreatedAt          string  `json:"createdAt"`
}

// ScanPage links a photographed page to a submission and scheme.
type ScanPage struct {
	ID            string  `json:"id"`
	SubmissionID  string  `json:"submissionId"`
	SchemeID      string  `json:"schemeId,omitempty"`
	PageNumber    int     `json:"pageNumber"`
	ImageID       string  `json:"imageId,omitempty"`
	OCRText       string  `json:"ocrText,omitempty"`
	OCRConfidence float64 `json:"ocrConfidence,omitempty"`
	OCRStatus     string  `json:"ocrStatus"`             // pending|processing|ready|needs_review|failed
	OCRMetadata   string  `json:"ocrMetadata,omitempty"` // JSON string
	CreatedAt     string  `json:"createdAt"`
}

// Draft statuses. A draft is never a mark: it becomes one only when a teacher
// finalizes it (Phase 6). A newer draft for the same paper discards the old.
const (
	DraftStatusDraft     = "draft"
	DraftStatusFinalized = "finalized"
	DraftStatusDiscarded = "discarded"
)

// Draft targets: which kind of paper a draft marks.
const (
	DraftTargetAssessment = "assessment"
	DraftTargetAssignment = "assignment"
)

// MarkingDraft is the matching engine's proposal for one student's paper
// against one exact scheme version (Phase 5).
type MarkingDraft struct {
	ID            string               `json:"id"`
	SchemeID      string               `json:"schemeId"`
	SchemeVersion int                  `json:"schemeVersion"`
	TargetKind    string               `json:"targetKind"`
	SubmissionID  string               `json:"submissionId"`
	StudentID     string               `json:"studentId"`
	ClassID       string               `json:"classId"`
	SourceText    string               `json:"sourceText"`
	OcrJobIDs     []string             `json:"ocrJobIds"`
	Unassigned    []string             `json:"unassigned"`
	Status        string               `json:"status"`
	DraftTotal    float64              `json:"draftTotal"`
	MaxTotal      float64              `json:"maxTotal"`
	NeedsReview   int                  `json:"needsReview"`
	CreatedBy     string               `json:"createdBy"`
	CreatedAt     string               `json:"createdAt"`
	FinalizedBy   string               `json:"finalizedBy,omitempty"`
	FinalizedAt   string               `json:"finalizedAt,omitempty"`
	Answers       []MarkingDraftAnswer `json:"answers"`
}

// MarkingDraftAnswer is one question of a draft: what was read, the proposed
// mark, and why. SchemeQuestionID is the per-question link to the scheme.
type MarkingDraftAnswer struct {
	SchemeQuestionID string      `json:"schemeQuestionId"`
	QuestionNumber   int         `json:"questionNumber"`
	StudentAnswer    string      `json:"studentAnswer"`
	Working          []string    `json:"working"`
	DraftMarks       float64     `json:"draftMarks"`
	TotalMarks       float64     `json:"totalMarks"`
	Method           string      `json:"method"`
	MatchedText      string      `json:"matchedText,omitempty"`
	MatchedAnswerID  int64       `json:"matchedAnswerId,omitempty"`
	MisconceptionID  int64       `json:"misconceptionId,omitempty"`
	LikelyCause      string      `json:"likelyCause,omitempty"`
	NeedsReview      bool        `json:"needsReview"`
	Reasons          []string    `json:"reasons"`
	Steps            []DraftStep `json:"steps"`
}

// DraftStep is one mark-breakdown step of a drafted question.
type DraftStep struct {
	StepID   string  `json:"stepId"`
	Type     string  `json:"type"`
	Criteria string  `json:"criteria"`
	Marks    float64 `json:"marks"`
	Awarded  float64 `json:"awarded"`
	Status   string  `json:"status"` // awarded | not_awarded | needs_review | set_by_answer
}
