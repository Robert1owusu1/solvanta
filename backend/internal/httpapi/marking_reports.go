package httpapi

import (
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/marking"
	"solvanta/backend/internal/matching"
)

// =============================================================================
// Marking feedback reports — Phase 7
// =============================================================================
//
// Both reports are built only from finalized drafts: the marks a teacher
// reviewed and recorded. A draft still waiting for review never appears, so
// a report can never show a mark nobody confirmed. Nothing is invented — a
// misconception is named only when the scheme's own misconception matched,
// and a next step comes from that, the question's topic, or a blank answer;
// failing all three it just says to go over the question.

// struggleThreshold: a class "struggled" with a question whose average is
// below this percentage of its marks.
const struggleThreshold = 50.0

// Next-step sources, so a client can say where the advice came from.
const (
	nextStepBlank         = "blank"
	nextStepMisconception = "misconception"
	nextStepTopic         = "topic"
	nextStepGeneral       = "general"
)

type feedbackQuestion struct {
	QuestionNumber int     `json:"questionNumber"`
	Topic          string  `json:"topic,omitempty"`
	StudentAnswer  string  `json:"studentAnswer"`
	Marks          float64 `json:"marks"`
	TotalMarks     float64 `json:"totalMarks"`
	Blank          bool    `json:"blank"`
	// LikelyMisconception is the cause the scheme gives for the wrong
	// answer this student wrote; empty when the scheme does not know.
	LikelyMisconception string `json:"likelyMisconception,omitempty"`
	NextStep            string `json:"nextStep"`
	NextStepSource      string `json:"nextStepSource"`
	// TeacherNote is the marker's own note; staff see it, a family does not.
	TeacherNote string `json:"teacherNote,omitempty"`
}

type feedbackPaper struct {
	DraftID       string             `json:"draftId"`
	SchemeID      string             `json:"schemeId"`
	SchemeVersion int                `json:"schemeVersion"`
	TargetKind    string             `json:"targetKind"`
	Title         string             `json:"title"`
	SubjectID     string             `json:"subjectId"`
	FinalizedAt   string             `json:"finalizedAt"`
	Marks         float64            `json:"marks"`
	Total         float64            `json:"total"`
	Percent       float64            `json:"percent"`
	Grade         string             `json:"grade"`
	QuestionCount int                `json:"questionCount"`
	FullMarks     int                `json:"fullMarks"`
	Wrong         []feedbackQuestion `json:"wrong"`
}

type causeCount struct {
	Cause string `json:"cause"`
	Count int    `json:"count"`
}

// paperTarget names what a scheme marks: its title, subject, and the
// assessment's question topics by question number (assignments have none).
type paperTarget struct {
	title     string
	subjectID string
	topics    map[int]string
}

func (s *Server) paperTargetFor(schemeID string, cache map[string]paperTarget) paperTarget {
	if t, ok := cache[schemeID]; ok {
		return t
	}
	t := paperTarget{title: "Marked work", topics: map[int]string{}}
	if ms, ok := s.store.MarkingSchemeByID(schemeID); ok {
		if a, ok := s.store.AssessmentByID(ms.AssessmentID); ok && ms.AssessmentID != "" {
			t.title, t.subjectID = a.Title, a.SubjectID
			for i, q := range a.Questions {
				t.topics[i+1] = strings.TrimSpace(q.Topic)
			}
		} else if asg, ok := s.store.AssignmentByID(ms.AssignmentID); ok && ms.AssignmentID != "" {
			t.title, t.subjectID = asg.Title, asg.SubjectID
		}
	}
	cache[schemeID] = t
	return t
}

// finalizedDrafts returns the full finalized drafts that pass keep.
func (s *Server) finalizedDrafts(keep func(domain.MarkingDraft) bool) []domain.MarkingDraft {
	var out []domain.MarkingDraft
	for _, h := range s.store.MarkingDraftsWithStatus(domain.DraftStatusFinalized) {
		if !keep(h) {
			continue
		}
		if d, ok := s.store.MarkingDraftByID(h.ID); ok && d.Status == domain.DraftStatusFinalized {
			out = append(out, d)
		}
	}
	return out
}

// finalOf is the recorded mark for a question of a finalized draft.
func finalOf(a domain.MarkingDraftAnswer) float64 {
	if a.FinalMarks != nil {
		return *a.FinalMarks
	}
	return 0
}

func isBlank(a domain.MarkingDraftAnswer) bool {
	return a.Method == string(matching.MethodBlank) || strings.TrimSpace(a.StudentAnswer) == ""
}

// nextStep picks advice from what is actually known about the answer.
func nextStep(a domain.MarkingDraftAnswer, topic string) (string, string) {
	n := strconv.Itoa(a.QuestionNumber)
	switch {
	case isBlank(a):
		return "Attempt question " + n + " — it was left blank.", nextStepBlank
	case a.LikelyCause != "":
		return "Work on this misconception: " + strings.TrimSuffix(a.LikelyCause, ".") + ".", nextStepMisconception
	case topic != "":
		return "Practise " + topic + ".", nextStepTopic
	default:
		return "Go over question " + n + " with your teacher.", nextStepGeneral
	}
}

// studentMarkingFeedback is the per-student report: for each finalized
// paper, the questions that did not get full marks, the likely misconception
// where the scheme names one, and a suggested next step.
func (s *Server) studentMarkingFeedback(c *gin.Context) {
	u := currentUser(c)
	st, ok := s.store.StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(u, st) || !teacherCoversClass(u, st.ClassID) {
		fail(c, http.StatusForbidden, "You may only view feedback for students you teach or your own family")
		return
	}
	staff := u.IsSchoolStaff()

	drafts := s.finalizedDrafts(func(d domain.MarkingDraft) bool { return d.StudentID == st.ID })
	sort.SliceStable(drafts, func(i, j int) bool { return drafts[i].FinalizedAt > drafts[j].FinalizedAt })

	targets := map[string]paperTarget{}
	causes := map[string]int{}
	papers := []feedbackPaper{}
	wrongTotal := 0
	for _, d := range drafts {
		t := s.paperTargetFor(d.SchemeID, targets)
		marks := d.FinalTotal()
		pct := 0.0
		if d.MaxTotal > 0 {
			pct = 100 * marks / d.MaxTotal
		}
		p := feedbackPaper{
			DraftID: d.ID, SchemeID: d.SchemeID, SchemeVersion: d.SchemeVersion, TargetKind: d.TargetKind,
			Title: t.title, SubjectID: t.subjectID, FinalizedAt: d.FinalizedAt,
			Marks: marks, Total: d.MaxTotal, Percent: pct, Grade: marking.GradeLetter(pct),
			QuestionCount: len(d.Answers), Wrong: []feedbackQuestion{},
		}
		for _, a := range d.Answers {
			got := finalOf(a)
			if got >= a.TotalMarks {
				p.FullMarks++
				continue
			}
			topic := t.topics[a.QuestionNumber]
			step, source := nextStep(a, topic)
			q := feedbackQuestion{
				QuestionNumber: a.QuestionNumber, Topic: topic, StudentAnswer: a.StudentAnswer,
				Marks: got, TotalMarks: a.TotalMarks, Blank: isBlank(a),
				LikelyMisconception: a.LikelyCause, NextStep: step, NextStepSource: source,
			}
			if staff {
				q.TeacherNote = a.TeacherNote
			}
			if a.LikelyCause != "" {
				causes[a.LikelyCause]++
			}
			p.Wrong = append(p.Wrong, q)
		}
		wrongTotal += len(p.Wrong)
		papers = append(papers, p)
	}

	sendJSON(c, gin.H{
		"student": gin.H{"id": st.ID, "name": st.FullName(), "classId": st.ClassID},
		"papers":  papers,
		"summary": gin.H{
			"papers":         len(papers),
			"wrongQuestions": wrongTotal,
			"misconceptions": sortedCauses(causes),
		},
	})
}

type classQuestionStat struct {
	QuestionNumber int          `json:"questionNumber"`
	Topic          string       `json:"topic,omitempty"`
	TotalMarks     float64      `json:"totalMarks"`
	Papers         int          `json:"papers"`
	AverageMarks   float64      `json:"averageMarks"`
	AveragePercent float64      `json:"averagePercent"`
	FullMarks      int          `json:"fullMarks"`
	Zero           int          `json:"zero"`
	Blank          int          `json:"blank"`
	Struggled      bool         `json:"struggled"`
	Misconceptions []causeCount `json:"misconceptions"`
	// BelowFull lists who lost marks, lowest first, so the teacher knows
	// whom to go over the question with.
	BelowFull []studentMark `json:"belowFull"`
}

type studentMark struct {
	StudentID string  `json:"studentId"`
	Name      string  `json:"name"`
	Marks     float64 `json:"marks"`
}

type classPaperReport struct {
	SchemeID       string              `json:"schemeId"`
	SchemeVersion  int                 `json:"schemeVersion"`
	TargetKind     string              `json:"targetKind"`
	Title          string              `json:"title"`
	SubjectID      string              `json:"subjectId"`
	Papers         int                 `json:"papers"`
	AwaitingReview int                 `json:"awaitingReview"`
	AveragePercent float64             `json:"averagePercent"`
	Questions      []classQuestionStat `json:"questions"`
	// Hardest is the struggled questions, worst first.
	Hardest      []int  `json:"hardest"`
	LastMarkedAt string `json:"lastMarkedAt"`
}

// classMarkingFeedback is the per-class aggregate: for each scheme the class
// has finalized papers on, how the class did on every question and which
// ones it struggled with.
func (s *Server) classMarkingFeedback(c *gin.Context) {
	u := currentUser(c)
	classID := c.Param("classId")
	if !teacherCoversClass(u, classID) {
		fail(c, http.StatusForbidden, "You may only view reports for your own class")
		return
	}

	drafts := s.finalizedDrafts(func(d domain.MarkingDraft) bool { return d.ClassID == classID })
	waiting := map[string]int{}
	for _, d := range s.store.MarkingDraftsWithStatus(domain.DraftStatusDraft) {
		if d.ClassID == classID {
			waiting[d.SchemeID]++
		}
	}

	byScheme := map[string][]domain.MarkingDraft{}
	var order []string
	for _, d := range drafts {
		if _, seen := byScheme[d.SchemeID]; !seen {
			order = append(order, d.SchemeID)
		}
		byScheme[d.SchemeID] = append(byScheme[d.SchemeID], d)
	}

	names := map[string]string{}
	nameOf := func(id string) string {
		if n, ok := names[id]; ok {
			return n
		}
		n := id
		if st, ok := s.store.StudentByID(id); ok {
			n = st.FullName()
		}
		names[id] = n
		return n
	}

	targets := map[string]paperTarget{}
	reports := []classPaperReport{}
	for _, schemeID := range order {
		ds := byScheme[schemeID]
		t := s.paperTargetFor(schemeID, targets)
		r := classPaperReport{
			SchemeID: schemeID, SchemeVersion: ds[0].SchemeVersion, TargetKind: ds[0].TargetKind,
			Title: t.title, SubjectID: t.subjectID, Papers: len(ds), AwaitingReview: waiting[schemeID],
			Questions: []classQuestionStat{}, Hardest: []int{},
		}
		stats := map[int]*classQuestionStat{}
		causes := map[int]map[string]int{}
		var pctSum float64
		for _, d := range ds {
			if d.FinalizedAt > r.LastMarkedAt {
				r.LastMarkedAt = d.FinalizedAt
			}
			if d.MaxTotal > 0 {
				pctSum += 100 * d.FinalTotal() / d.MaxTotal
			}
			for _, a := range d.Answers {
				q := stats[a.QuestionNumber]
				if q == nil {
					q = &classQuestionStat{QuestionNumber: a.QuestionNumber, Topic: t.topics[a.QuestionNumber],
						TotalMarks: a.TotalMarks, BelowFull: []studentMark{}}
					stats[a.QuestionNumber] = q
					causes[a.QuestionNumber] = map[string]int{}
				}
				got := finalOf(a)
				q.Papers++
				q.AverageMarks += got
				switch {
				case got >= a.TotalMarks:
					q.FullMarks++
				default:
					q.BelowFull = append(q.BelowFull, studentMark{StudentID: d.StudentID, Name: nameOf(d.StudentID), Marks: got})
				}
				if got == 0 {
					q.Zero++
				}
				if isBlank(a) {
					q.Blank++
				}
				if a.LikelyCause != "" && got < a.TotalMarks {
					causes[a.QuestionNumber][a.LikelyCause]++
				}
			}
		}
		r.AveragePercent = pctSum / float64(len(ds))
		for _, q := range stats {
			q.AverageMarks /= float64(q.Papers)
			if q.TotalMarks > 0 {
				q.AveragePercent = 100 * q.AverageMarks / q.TotalMarks
			}
			q.Struggled = q.AveragePercent < struggleThreshold
			q.Misconceptions = sortedCauses(causes[q.QuestionNumber])
			sort.SliceStable(q.BelowFull, func(i, j int) bool { return q.BelowFull[i].Marks < q.BelowFull[j].Marks })
			r.Questions = append(r.Questions, *q)
		}
		sort.Slice(r.Questions, func(i, j int) bool { return r.Questions[i].QuestionNumber < r.Questions[j].QuestionNumber })
		hardest := make([]classQuestionStat, 0)
		for _, q := range r.Questions {
			if q.Struggled {
				hardest = append(hardest, q)
			}
		}
		sort.SliceStable(hardest, func(i, j int) bool { return hardest[i].AveragePercent < hardest[j].AveragePercent })
		for _, q := range hardest {
			r.Hardest = append(r.Hardest, q.QuestionNumber)
		}
		reports = append(reports, r)
	}
	sort.SliceStable(reports, func(i, j int) bool { return reports[i].LastMarkedAt > reports[j].LastMarkedAt })

	// Papers still in review are counted even where nothing is finalized yet,
	// so the teacher sees why a scheme is missing from the report.
	pending := 0
	for _, n := range waiting {
		pending += n
	}
	sendJSON(c, gin.H{
		"classId":           classID,
		"struggleThreshold": struggleThreshold,
		"reports":           reports,
		"awaitingReview":    pending,
	})
}

// sortedCauses orders misconceptions by how often they were seen.
func sortedCauses(m map[string]int) []causeCount {
	out := make([]causeCount, 0, len(m))
	for cause, n := range m {
		out = append(out, causeCount{Cause: cause, Count: n})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Cause < out[j].Cause
	})
	return out
}
