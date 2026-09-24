// Package marking mirrors the Flutter app's marking & analytics logic so the
// backend computes identical results to the client: computeEarned (doc §26),
// gradeLetter, the blueprint pick (doc §18) and learning-gap analysis
// (doc §27–30).
package marking

import (
	"math"
	"sort"
	"strconv"
	"strings"

	"solvanta/backend/internal/domain"
)

// ComputeEarned mirrors computeEarned() in submission.dart: objective answers
// are auto-marked by exact (trimmed, lower-cased) match; everything else is
// taken from teacher marks.
func ComputeEarned(questions []domain.Question, answers map[string]string, teacherMarks map[string]float64) float64 {
	var total float64
	for _, q := range questions {
		if q.IsObjective() {
			a := strings.ToLower(strings.TrimSpace(answers[q.ID]))
			correct := strings.ToLower(strings.TrimSpace(q.CorrectAnswer))
			if a != "" && a == correct {
				total += q.Marks
			}
		} else {
			total += teacherMarks[q.ID]
		}
	}
	return total
}

// GradeLetter mirrors gradeLetter() in analytics_service.dart.
func GradeLetter(percent float64) string {
	switch {
	case percent >= 85:
		return "A"
	case percent >= 70:
		return "B"
	case percent >= 60:
		return "C"
	case percent >= 50:
		return "D"
	default:
		return "F"
	}
}

// NumericEquivalence evaluates math-type answers: "3/4" == "0.75" == "75%".
// Falls back to exact trimmed match when both sides parse as numbers.
func NumericEquivalence(a, b string) bool {
	va, oka := parseNumber(a)
	vb, okb := parseNumber(b)
	if oka && okb {
		const eps = 1e-9
		return math.Abs(va-vb) < eps
	}
	return strings.ToLower(strings.TrimSpace(a)) == strings.ToLower(strings.TrimSpace(b))
}

func parseNumber(s string) (float64, bool) {
	s = strings.TrimSpace(s)
	if strings.HasSuffix(s, "%") {
		v, err := strconv.ParseFloat(strings.TrimSuffix(s, "%"), 64)
		return v / 100, err == nil
	}
	if parts := strings.SplitN(s, "/", 2); len(parts) == 2 {
		n, errN := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
		d, errD := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
		if errN == nil && errD == nil && d != 0 {
			return n / d, true
		}
		return 0, false
	}
	v, err := strconv.ParseFloat(s, 64)
	return v, err == nil
}

// BlueprintPick mirrors AssessmentRepository.blueprintPick: filter by
// subject/topic, fall back to the subject, shuffle and take n.
func BlueprintPick(from []domain.Question, topic, subjectID string, count int) []domain.Question {
	if count < 0 {
		count = 0
	}
	pool := filterBy(from, func(q domain.Question) bool {
		return (subjectID == "" || q.SubjectID == subjectID) &&
			(topic == "" || q.Topic == topic)
	})
	if len(pool) == 0 {
		pool = filterBy(from, func(q domain.Question) bool {
			return subjectID == "" || q.SubjectID == subjectID
		})
	}
	shuffle(pool)
	if count > len(pool) {
		count = len(pool)
	}
	return pool[:count]
}

type questionPred func(domain.Question) bool

func filterBy(in []domain.Question, keep questionPred) []domain.Question {
	out := make([]domain.Question, 0, len(in))
	for _, q := range in {
		if keep(q) {
			out = append(out, q)
		}
	}
	return out
}

// shuffled pseudo-random Fisher–Yates (deterministic-style, fine for dev).
func shuffle(s []domain.Question) {
	seed := uint64(88172645463325252) ^ (uint64(len(s)) * uint64(0x9e3779b97f4a7c15))
	for i := len(s) - 1; i > 0; i-- {
		seed = seed*6364136223846793005 + 1442695040888963407
		j := int((seed >> 32) % uint64(i+1))
		s[i], s[j] = s[j], s[i]
	}
}

// QuestionPerformance mirrors analytics_service.QuestionPerformance.
type QuestionPerformance struct {
	QuestionID     string  `json:"questionId"`
	Topic          string  `json:"topic"`
	CognitiveLevel string  `json:"cognitiveLevel"`
	SubjectID      string  `json:"subjectId"`
	Marks          float64 `json:"marks"`
	Attempts       int     `json:"attempts"`
	CorrectRate    float64 `json:"correctRate"`
	Gap            float64 `json:"gap"`
}

// StudentAlert mirrors analytics_service.StudentAlert (doc §27).
type StudentAlert struct {
	Student               domain.Student `json:"student"`
	Average               float64        `json:"average"`
	Grade                 string         `json:"grade"`
	SuggestedIntervention string         `json:"suggestedIntervention"`
}

// ClassPerformance mirrors analytics_service.ClassPerformance.
type ClassPerformance struct {
	Assessments []domain.Assessment
	Subs        []domain.Submission
	Students    []domain.Student
}

func (c ClassPerformance) subsFor(assessmentID string) []domain.Submission {
	var out []domain.Submission
	for _, s := range c.Subs {
		if s.AssessmentID == assessmentID {
			out = append(out, s)
		}
	}
	return out
}

func (c ClassPerformance) assessment(id string) (domain.Assessment, bool) {
	for _, a := range c.Assessments {
		if a.ID == id {
			return a, true
		}
	}
	return domain.Assessment{}, false
}

// AssessmentAverage returns the mean earned ratio (0..1) for an assessment.
func (c ClassPerformance) AssessmentAverage(a domain.Assessment) float64 {
	list := c.subsFor(a.ID)
	if len(list) == 0 || a.TotalMarks() <= 0 {
		return 0
	}
	var sum float64
	for _, s := range list {
		sum += s.Earned / a.TotalMarks()
	}
	return sum / float64(len(list))
}

// Distribution returns grade → count for an assessment (doc §26).
func (c ClassPerformance) Distribution(a domain.Assessment) map[string]int {
	out := map[string]int{"A": 0, "B": 0, "C": 0, "D": 0, "F": 0}
	for _, s := range c.subsFor(a.ID) {
		pct := 0.0
		if tm := a.TotalMarks(); tm > 0 {
			pct = 100 * s.Earned / tm
		}
		out[GradeLetter(pct)]++
	}
	return out
}

// QuestionIsCorrect mirrors the per-question correctness rule used by
// gapsFor() in the app.
func QuestionIsCorrect(q domain.Question, sub domain.Submission) bool {
	a := strings.ToLower(strings.TrimSpace(sub.Answers[q.ID]))
	if q.IsObjective() {
		return a != "" && a == strings.ToLower(strings.TrimSpace(q.CorrectAnswer))
	}
	return sub.TeacherMarks[q.ID] >= q.Marks*0.8
}

// Gaps returns per-question performance sorted by biggest gap first (doc §29–30).
func (c ClassPerformance) Gaps(a domain.Assessment) []QuestionPerformance {
	list := c.subsFor(a.ID)
	if len(list) == 0 {
		return nil
	}
	var out []QuestionPerformance
	for _, q := range a.Questions {
		correct := 0
		for _, sub := range list {
			if QuestionIsCorrect(q, sub) {
				correct++
			}
		}
		rate := float64(correct) / float64(len(list))
		out = append(out, QuestionPerformance{
			QuestionID:     q.ID,
			Topic:          q.Topic,
			CognitiveLevel: q.CognitiveLevel,
			SubjectID:      a.SubjectID,
			Marks:          q.Marks,
			Attempts:       len(list),
			CorrectRate:    rate,
			Gap:            1 - rate,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Gap > out[j].Gap })
	return out
}

// AtRisk mirrors analytics_service.atRisk (doc §27): students averaging below
// threshold with a suggested intervention naming their weakest topic.
func (c ClassPerformance) AtRisk(threshold float64) []StudentAlert {
	var out []StudentAlert
	for _, s := range c.Students {
		var mine []domain.Submission
		for _, m := range c.Subs {
			if m.StudentID == s.ID && m.ClassID == s.ClassID {
				mine = append(mine, m)
			}
		}
		if len(mine) == 0 {
			continue
		}
		var earned, possible float64
		for _, m := range mine {
			a, ok := c.assessment(m.AssessmentID)
			if !ok {
				continue
			}
			earned += m.Earned
			possible += a.TotalMarks()
		}
		pct := 0.0
		if possible > 0 {
			pct = 100 * earned / possible
		}
		if pct < threshold {
			weak := c.weakTopic(s)
			msg := "Re-teach & practice on core topics; reassess in 2 weeks"
			if weak != "" {
				msg = "Re-teach & practice on " + weak + "; reassess in 2 weeks"
			}
			out = append(out, StudentAlert{
				Student:               s,
				Average:               pct,
				Grade:                 GradeLetter(pct),
				SuggestedIntervention: msg,
			})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Average < out[j].Average })
	return out
}

func (c ClassPerformance) weakTopic(s domain.Student) string {
	incorrect := map[string]int{}
	for _, sub := range c.Subs {
		if sub.StudentID != s.ID {
			continue
		}
		a, ok := c.assessment(sub.AssessmentID)
		if !ok {
			continue
		}
		for _, q := range a.Questions {
			if !QuestionIsCorrect(q, sub) {
				incorrect[q.Topic]++
			}
		}
	}
	var worst string
	var worstCount int
	for topic, n := range incorrect {
		if n > worstCount {
			worst, worstCount = topic, n
		}
	}
	return worst
}

// WeakTopics computes per-topic accuracy for a student across all marked
// objective work, mirroring topicStrength() used by prep/vacation (doc §44–45).
type WeakTopic struct {
	SubjectID string  `json:"subjectId"`
	Topic     string  `json:"topic"`
	Correct   int     `json:"correct"`
	Total     int     `json:"total"`
	Pct       float64 `json:"pct"`
}

func WeakTopics(studentID string, assessments []domain.Assessment, subs []domain.Submission) []WeakTopic {
	counters := map[string][2]int{}
	for _, a := range assessments {
		for _, q := range a.Questions {
			if !q.IsObjective() {
				continue
			}
			for _, s := range subs {
				if s.AssessmentID != a.ID || s.StudentID != studentID {
					continue
				}
				key := a.SubjectID + "|" + q.Topic
				c := counters[key]
				c[1]++
				got := strings.ToLower(strings.TrimSpace(s.Answers[q.ID]))
				if got != "" && got == strings.ToLower(strings.TrimSpace(q.CorrectAnswer)) {
					c[0]++
				}
				counters[key] = c
			}
		}
	}
	var out []WeakTopic
	for key, c := range counters {
		parts := strings.SplitN(key, "|", 2)
		out = append(out, WeakTopic{
			SubjectID: parts[0],
			Topic:     parts[1],
			Correct:   c[0],
			Total:     c[1],
			Pct:       100 * float64(c[0]) / float64(c[1]),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Pct < out[j].Pct })
	return out
}
