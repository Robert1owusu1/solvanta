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
