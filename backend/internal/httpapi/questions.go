package httpapi

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
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
	s.store.SaveQuestion(q)
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
	s.store.SaveQuestion(q)
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
	s.store.DeleteQuestion(id)
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
	req := domain.GenRequest{
		ID:            newID("QGEN"),
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
	s.store.SaveAIRequest(req)
	s.audit(c, "questiongen.req", req.ID, "Requested "+itoa(req.Count)+" "+req.Type+" on "+req.Topic, "")
	sendCreated(c, req)
}

// aiGenerate simulates the Python AI pipeline (doc §43, §54): it writes
// template drafts for the requested count and moves the request to "generated".
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
	drafts := questionDraftFor(req)
	req.Drafts = drafts
	req.Status = domain.QGenGenerated
	s.store.SaveAIRequest(req)
	s.notify(req.RequesterID, domain.NotifAssessment,
		"AI question drafts ready",
		itoa(len(drafts))+" "+req.Type+" questions drafted for "+req.SubjectID+" · "+req.Topic+". Review them.",
		"")
	s.audit(c, "questiongen.generate", req.ID, "Generated "+itoa(len(drafts))+" drafts", "")
	sendJSON(c, req)
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
		s.store.SaveQuestion(req.Drafts[i])
	}
	req.Status = domain.QGenPublished
	req.PublishedAt = now()
	s.store.SaveAIRequest(req)
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
	s.store.SaveAIRequest(req)
	s.audit(c, "questiongen.reject", req.ID, "Rejected generation request", "")
	sendJSON(c, req)
}

// questionDraftFor templates plausible questions for the requested subject and
// topic using the curriculum bank as inspiration.
func questionDraftFor(req domain.GenRequest) []domain.Question {
	classID := req.ClassID
	if classID == "" {
		classID = "JHS2A"
	}
	var out []domain.Question
	qtype := req.Type
	for i := 1; i <= req.Count; i++ {
		out = append(out, domain.Question{
			ID:             newID("Q"),
			Type:           qtype,
			SubjectID:      req.SubjectID,
			ClassID:        classID,
			Topic:          req.Topic,
			Difficulty:     (i % 3) + 1,
			CognitiveLevel: levelFor(i),
			Marks:          2.0,
			Stem:           req.Topic + " — draft question " + itoa(i) + ". Review and edit before publishing.",
			Options:        []string{"Option A", "Option B", "Option C", "Option D"},
			CorrectAnswer:  "Option A",
			Explanation:    "AI-drafted answer; verify against the topic material.",
		})
	}
	return out
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
