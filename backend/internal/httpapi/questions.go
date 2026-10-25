package httpapi

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/ocr"
)

// validCognitiveLevels mirrors the app's four-value cognitive level set.
var validCognitiveLevels = map[string]bool{
	"Knowledge": true, "Comprehension": true,
	"Application": true, "Analysis": true,
}

// validQuestionTypes mirrors the app's QuestionType enum (lib/core/models/question.dart).
var validQuestionTypes = map[string]bool{
	domain.QTypeMCQ: true, domain.QTypeTrueFalse: true,
	domain.QTypeFillBlank: true, domain.QTypeShortAnswer: true,
	domain.QTypeStructured: true, domain.QTypeMath: true,
	domain.QTypeEssay: true, domain.QTypePractical: true,
}

func validSubject(id string) bool {
	for _, s := range domain.Subjects {
		if s.ID == id {
			return true
		}
	}
	return false
}

// createQuestion adds a question to the bank (doc §17).
func (s *Server) createQuestion(c *gin.Context) {
	var q domain.Question
	if !bind(c, &q) {
		return
	}
	u := currentUser(c)
	if !validQuestionTypes[q.Type] {
		fail(c, http.StatusBadRequest, "Unknown question type")
		return
	}
	if strings.TrimSpace(q.Stem) == "" {
		fail(c, http.StatusBadRequest, "stem is required")
		return
	}
	if !validSubject(q.SubjectID) {
		fail(c, http.StatusBadRequest, "Unknown subjectId")
		return
	}
	if q.Marks <= 0 {
		fail(c, http.StatusBadRequest, "marks must be greater than zero")
		return
	}
	if q.Difficulty < 1 || q.Difficulty > 3 {
		fail(c, http.StatusBadRequest, "difficulty must be between 1 and 3")
		return
	}
	if q.CognitiveLevel != "" && !validCognitiveLevels[q.CognitiveLevel] {
		fail(c, http.StatusBadRequest, "Unknown cognitive level")
		return
	}
	if q.Type == domain.QTypeMCQ {
		if len(q.Options) < 2 || len(q.Options) > 4 {
			fail(c, http.StatusBadRequest, "mcq questions need 2 to 4 options")
			return
		}
		if strings.TrimSpace(q.CorrectAnswer) == "" {
			fail(c, http.StatusBadRequest, "correctAnswer is required for mcq questions")
			return
		}
	}
	if q.Type == domain.QTypeTrueFalse && q.CorrectAnswer != "True" && q.CorrectAnswer != "False" {
		fail(c, http.StatusBadRequest, "correctAnswer must be 'True' or 'False' for true/false questions")
		return
	}
	if q.ID == "" {
		q.ID = newID("Q")
	}
	if q.ClassID == "" {
		q.ClassID = u.ClassID
	}
	if writeFailed(c, s.store.SaveQuestion(q)) {
		return
	}
	s.audit(c, "question.create", q.ID, "Added "+q.Type+" question on "+q.Topic, "")
	sendCreated(c, q)
}

// updateQuestion edits banked/approved questions.
func (s *Server) updateQuestion(c *gin.Context) {
	q, ok := s.store.QuestionByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Question not found")
		return
	}
	if !bind(c, &q) {
		return
	}
	if writeFailed(c, s.store.SaveQuestion(q)) {
		return
	}
	s.audit(c, "question.update", q.ID, "Updated question on "+q.Topic, "")
	sendJSON(c, q)
}

// deleteQuestion removes a question (doc §17).
func (s *Server) deleteQuestion(c *gin.Context) {
	id := c.Param("id")
	if _, ok := s.store.QuestionByID(id); !ok {
		fail(c, http.StatusNotFound, "Question not found")
		return
	}
	if writeFailed(c, s.store.DeleteQuestion(id)) {
		return
	}
	s.audit(c, "question.delete", id, "Deleted question", "")
	sendJSON(c, gin.H{"deleted": id})
}

// aiRequests lists AI question-generation requests (doc §43).
func (s *Server) aiRequests(c *gin.Context) {
	sendJSON(c, s.store.AIRequests())
}

// aiRequest creates a generation request (status pending).
func (s *Server) aiRequest(c *gin.Context) {
	u := currentUser(c)
	var body domain.GenRequest
	if !bind(c, &body) {
		return
	}
	if body.ID != "" {
		if _, exists := s.store.AIRequestByID(body.ID); exists {
			fail(c, http.StatusConflict, "A request with this id already exists")
			return
		}
	}
	req := domain.GenRequest{
		ID:            firstNonEmpty(body.ID, newID("QGEN")),
		RequesterID:   u.ID,
		RequesterName: u.Name,
		SubjectID:     body.SubjectID,
		Topic:         body.Topic,
		Type:          body.Type,
		Count:         body.Count,
		Priority:      firstNonEmpty(body.Priority, "normal"),
		ClassID:       firstNonEmpty(body.ClassID, u.ClassID),
		CreatedAt:     now(),
		Status:        domain.QGenPending,
	}
	if writeFailed(c, s.store.SaveAIRequest(req)) {
		return
	}
	s.audit(c, "questiongen.req", req.ID, "Requested "+itoa(req.Count)+" "+req.Type+" on "+req.Topic, "")
	sendCreated(c, req)
}

// generateInput is the optional body on the generate call.
//
// Optional because the client already posts nothing here (see
// QuestionGenRepository.update, which passes a null body), and making the body
// required would break a working path for no gain. When a photo is supplied it
// is what the recogniser reads; when it is not, the recogniser still runs and —
// on a deployment with no keys — the mock's deterministic text stands in.
type generateInput struct {
	// ImageBase64 is the photo to recognise. A data-URL prefix is accepted
	// and stripped, so callers need not know which form the far end wants.
	ImageBase64 string `json:"imageBase64"`
	// ContentType labels the photo; absent, the recogniser assumes JPEG.
	ContentType string `json:"contentType"`
	// OcrProvider is the question-level routing override for mixed subjects:
	// "mathpix", "google_vision", or "mock". Empty inherits the subject-level
	// default (Maths → math notation, everything else → plain handwriting).
	// An unknown value is ignored rather than honoured, so a typo in a config
	// can never route a student's page to an unintended engine.
	OcrProvider string `json:"ocrProvider"`
}

// generateResponse is the generation request with its OCR run attached.
//
// The GenRequest is EMBEDDED, not nested: the existing client decodes this
// response straight into QuestionGenRequest, and wrapping it in {"request":
// {...}} would silently empty every field the review screen reads while still
// parsing without error. Embedding keeps every field exactly where it was and
// adds "ocr" alongside, so this is additive for old callers.
type generateResponse struct {
	domain.GenRequest
	OCR ocrSummary `json:"ocr"`
}

// ocrSummary is what the teacher confirmation step needs, and nothing more:
// what the engine said, which engine said it, how sure it was, and how the
// page billed. No photo bytes and nothing identifying the student — this
// travels through the same logs and caches as any other API response.
//
// Confirmed is always false when written here. Nothing may mark OCR output as
// accepted on the way out of the server: acceptance is a teacher's act, taken
// at the confirmation screen, and pre-setting it here would make the flag
// meaningless.
type ocrSummary struct {
	Text       string       `json:"text"`
	Math       string       `json:"math,omitempty"`
	Provider   ocr.Kind     `json:"provider"`
	CostTier   ocr.CostTier `json:"costTier"`
	Lines      int          `json:"lines"`
	Confidence float64      `json:"confidence"`
	Warnings   []string     `json:"warnings"`
	Confirmed  bool         `json:"confirmed"`
}

func summarize(res *ocr.Result) ocrSummary {
	w := res.Warnings
	if w == nil {
		w = []string{} // never null: a UI ranging over warnings must not null-check
	}
	return ocrSummary{
		Text:       res.Text,
		Math:       res.Math,
		Provider:   res.Provider,
		CostTier:   res.CostTier,
		Lines:      res.Lines,
		Confidence: res.Confidence,
		Warnings:   w,
		Confirmed:  false,
	}
}

// aiGenerate runs the OCR pipeline for this request and turns what it reads
// into drafts a teacher can review (doc §43, §54).
//
// This is where a templated stand-in for an AI pipeline used to sit. The
// recogniser now runs for real: Mathpix for maths content, Cloud Vision for
// plain handwriting, or the mock when the relevant key is not installed — so
// the endpoint answers on a machine with no credentials rather than failing to
// start or hanging on a network call nobody can make.
//
// A recogniser failure stops generation outright rather than falling back to
// mock text. Falling back would hand the teacher fabricated words labelled as
// a reading of a real page, which is precisely the failure this phase exists
// to prevent; a 502 that says what went wrong is the honest answer.
func (s *Server) aiGenerate(c *gin.Context) {
	id := c.Param("id")
	req, ok := s.store.AIRequestByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Request not found")
		return
	}
	if req.Status != domain.QGenPending && req.Status != domain.QGenRejected {
		fail(c, http.StatusConflict, "Request already generated")
		return
	}

	var in generateInput
	if hasBody(c) {
		if !bind(c, &in) {
			return
		}
	}
	image, err := decodeImageB64(in.ImageBase64)
	if err != nil {
		fail(c, http.StatusBadRequest, err.Error())
		return
	}

	provider := s.ocrs.Provider(req.SubjectID, in.OcrProvider)
	res, err := provider.Recognize(c.Request.Context(), ocr.Input{
		PageID:      req.ID,
		Image:       image,
		ContentType: in.ContentType,
		SubjectID:   req.SubjectID,
	})
	if err != nil {
		fail(c, http.StatusBadGateway, "OCR failed: "+err.Error())
		return
	}
	// Logged on every run, key or no key, so the rate-tier line is exercised
	// by the test suite before real money is ever attached to it.
	ocr.LogCost(req.ID, res)

	drafts := questionDraftFor(req, res)
	req.Drafts = drafts
	req.Status = domain.QGenGenerated
	if writeFailed(c, s.store.SaveAIRequest(req)) {
		return
	}
	s.notify(req.RequesterID, domain.NotifAssessment,
		"AI question drafts ready",
		itoa(len(drafts))+" "+req.Type+" questions drafted for "+req.SubjectID+" · "+req.Topic+". Review them.",
		"")
	s.audit(c, "questiongen.generate", req.ID,
		"Recognised "+itoa(res.Lines)+" lines via "+string(res.Provider)+" ("+string(res.CostTier)+" rate), "+itoa(len(drafts))+" drafts", "")
	sendJSON(c, generateResponse{GenRequest: req, OCR: summarize(res)})
}

// hasBody reports whether the request carried a body worth decoding.
//
// ContentLength is 0 for the no-body calls the client already makes and -1
// when a transfer is chunked (a body with an unknown size — which is a body).
// Treating 0 as "nothing to decode" keeps the old callers working without
// routing them through a JSON parse they never asked for.
func hasBody(c *gin.Context) bool {
	return c.Request != nil && c.Request.ContentLength != 0
}

// decodeImageB64 decodes the optional photo, accepting both the raw base64
// form and a data-URL, since callers reach for either.
func decodeImageB64(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	if i := strings.Index(s, ","); i >= 0 && strings.HasPrefix(s, "data:") {
		s = s[i+1:]
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("imageBase64 is not valid base64")
	}
	return b, nil
}

// aiPublish approves the drafts into the question bank (status published).
func (s *Server) aiPublish(c *gin.Context) {
	id := c.Param("id")
	req, ok := s.store.AIRequestByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Request not found")
		return
	}
	if req.Status != domain.QGenGenerated {
		fail(c, http.StatusConflict, "Request must be generated before publishing")
		return
	}
	for i := range req.Drafts {
		if req.Drafts[i].ID == "" {
			req.Drafts[i].ID = newID("Q")
		}
		if writeFailed(c, s.store.SaveQuestion(req.Drafts[i])) {
			return
		}
	}
	req.Status = domain.QGenPublished
	req.PublishedAt = now()
	if writeFailed(c, s.store.SaveAIRequest(req)) {
		return
	}
	s.notify(req.RequesterID, domain.NotifAssessment,
		"Questions published to the bank",
		itoa(len(req.Drafts))+" "+req.SubjectID+" questions on "+req.Topic+" are now in the question bank.",
		"")
	s.audit(c, "questiongen.publish", req.ID, "Published "+itoa(len(req.Drafts))+" questions", "")
	sendJSON(c, req)
}

// aiReject rejects the request without saving to the bank.
func (s *Server) aiReject(c *gin.Context) {
	id := c.Param("id")
	req, ok := s.store.AIRequestByID(id)
	if !ok {
		fail(c, http.StatusNotFound, "Request not found")
		return
	}
	req.Status = domain.QGenRejected
	req.Drafts = nil
	if writeFailed(c, s.store.SaveAIRequest(req)) {
		return
	}
	s.audit(c, "questiongen.reject", req.ID, "Rejected generation request", "")
	sendJSON(c, req)
}

// questionDraftFor builds draft questions from what the recogniser actually
// read on this page.
//
// The stems quote recognised text rather than inventing it: with a photo
// attached the drafts are grounded in that photo, and with none — the normal
// case on a deployment with no keys — they are grounded in the mock's
// deterministic text, which announces itself as synthetic and so can never be
// mistaken for a student's work.
//
// The option scaffolding and placeholder answer are unchanged from before this
// phase; they are placeholders a teacher replaces, a draft reaches the bank
// only through an explicit publish, and changing them belongs to the review UI
// in Phase 6 rather than to this change. What is new is provenance: every
// draft says which engine produced it and how sure that engine was, so no
// draft can quietly be mistaken for one a human wrote.
func questionDraftFor(req domain.GenRequest, res *ocr.Result) []domain.Question {
	classID := req.ClassID
	if classID == "" {
		classID = "JHS2A"
	}
	source := sourceExcerpts(res.Text)
	provenance := provenanceFor(res)

	var out []domain.Question
	for i := 1; i <= req.Count; i++ {
		out = append(out, domain.Question{
			ID:             newID("Q"),
			Type:           req.Type,
			SubjectID:      req.SubjectID,
			ClassID:        classID,
			Topic:          req.Topic,
			Difficulty:     (i % 3) + 1,
			CognitiveLevel: levelFor(i),
			Marks:          2.0,
			Stem:           req.Topic + " — " + source[(i-1)%len(source)],
			Options:        []string{"Option A", "Option B", "Option C", "Option D"},
			CorrectAnswer:  "Option A",
			Explanation:    provenance,
		})
	}
	return out
}

// sourceExcerpts splits recognised text into the per-line excerpts drafts are
// built from.
//
// Always returns at least one entry: a page that read as nothing still has to
// yield a stem, and a zero-length slice here would divide by zero in the loop
// above. Saying "no readable text" is also the truthful thing to put in front
// of a teacher.
func sourceExcerpts(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	if len(out) == 0 {
		return []string{"(this page returned no readable text)"}
	}
	return out
}

// provenanceFor describes where a draft came from and how sure the engine was.
//
// An unreported confidence is stated as unreported rather than printed as 0%:
// "0% confident" reads as a definite judgement that the page is illegible,
// when the truth is that the engine offered no judgement at all.
func provenanceFor(res *ocr.Result) string {
	if res.Confidence > 0 {
		return fmt.Sprintf(
			"Recognised by %s: %.0f%% confidence across %d lines. Review and edit before publishing.",
			res.Provider, res.Confidence*100, res.Lines)
	}
	return fmt.Sprintf(
		"Recognised by %s: confidence not reported, %d lines. Review and edit before publishing.",
		res.Provider, res.Lines)
}

func levelFor(i int) string {
	switch (i - 1) % 4 {
	case 0:
		return "Knowledge"
	case 1:
		return "Comprehension"
	case 2:
		return "Application"
	default:
		return "Analysis"
	}
}
