// Package matching drafts marks by comparing a student's confirmed answers
// with a structured marking scheme (Phase 5).
//
// Everything it produces is a DRAFT for a teacher to review: Result.Final is
// always false, and nothing here writes a grade. When the scheme does not
// cover what the student wrote, the question is flagged rather than given a
// guessed mark.
//
// Matching runs from most to least certain:
//
//  1. exact       — the answer as written equals an accepted answer
//  2. normalized  — equal once case, spacing and symbol variants are ignored
//  3. numeric     — the same number written the same way ("0.50" = "0.5")
//  4. flagged     — same value in another form ("1/2" vs "0.5"), a missing
//     or different unit, or a rounding: the variant's marks are
//     proposed, but a teacher must confirm
//  5. misconception — a wrong answer the scheme names, with its partial
//     credit and likely cause
//  6. none        — not in the scheme: 0 proposed, flagged for review
package matching

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"solvanta/backend/internal/domain"
)

// Method says how a question's answer was matched.
type Method string

const (
	MethodExact         Method = "exact"
	MethodNormalized    Method = "normalized"
	MethodNumeric       Method = "numeric"
	MethodEquivalent    Method = "equivalent_form" // same value, other form
	MethodUnit          Method = "unit_mismatch"
	MethodRounded       Method = "rounded"
	MethodMisconception Method = "misconception"
	MethodNone          Method = "none"
	MethodBlank         Method = "blank"
)

// Status of one breakdown step.
type StepStatus string

const (
	StepAwarded     StepStatus = "awarded"
	StepNotAwarded  StepStatus = "not_awarded"
	StepNeedsReview StepStatus = "needs_review"
	// StepByVariant: the question's marks come from an accepted answer worth
	// part of the total, and the scheme does not say which steps that covers.
	StepByVariant StepStatus = "set_by_answer"
)

// Answer is one question's confirmed answer.
type Answer struct {
	QuestionNumber int      `json:"questionNumber"`
	Text           string   `json:"text"`              // the final answer
	Working        []string `json:"working,omitempty"` // any lines of working
	// Notes from splitting the page into questions ("taken from the last
	// line"), carried into the result so the teacher sees how it was read.
	Notes []string `json:"notes,omitempty"`
}

// StepResult is one mark-breakdown step's draft.
type StepResult struct {
	StepID   string     `json:"stepId"`
	Type     string     `json:"type"`
	Criteria string     `json:"criteria"`
	Marks    float64    `json:"marks"`
	Awarded  float64    `json:"awarded"`
	Status   StepStatus `json:"status"`
}

// QuestionResult is the draft for one question: what was read, the proposed
// mark, and why.
type QuestionResult struct {
	QuestionNumber   int          `json:"questionNumber"`
	SchemeQuestionID string       `json:"schemeQuestionId"`
	StudentAnswer    string       `json:"studentAnswer"`
	Working          []string     `json:"working,omitempty"`
	DraftMarks       float64      `json:"draftMarks"`
	TotalMarks       float64      `json:"totalMarks"`
	Method           Method       `json:"method"`
	MatchedText      string       `json:"matchedText,omitempty"`
	MatchedAnswerID  int64        `json:"matchedAnswerId,omitempty"`
	MisconceptionID  int64        `json:"misconceptionId,omitempty"`
	LikelyCause      string       `json:"likelyCause,omitempty"`
	NeedsReview      bool         `json:"needsReview"`
	Reasons          []string     `json:"reasons"`
	Steps            []StepResult `json:"steps"`
}

// Result is a whole script's draft.
type Result struct {
	Questions   []QuestionResult `json:"questions"`
	DraftTotal  float64          `json:"draftTotal"`
	MaxTotal    float64          `json:"maxTotal"`
	NeedsReview int              `json:"needsReview"` // questions flagged
	// Unassigned is text that could not be attributed to any question in
	// the scheme. Never dropped silently: it is shown for review.
	Unassigned []string `json:"unassigned"`
	// Final is always false. Drafts become marks only through a teacher.
	Final bool `json:"final"`
}

// candidate is one way an answer could be marked; the strongest wins.
type candidate struct {
	rank        int // lower is more certain
	method      Method
	marks       float64
	text        string
	answerID    int64
	miscID      int64
	cause       string
	needsReview bool
	reason      string
}

// MarkQuestion drafts one question.
func MarkQuestion(q domain.SchemeQuestion, a Answer) QuestionResult {
	res := QuestionResult{
		QuestionNumber:   q.QuestionNumber,
		SchemeQuestionID: q.ID,
		StudentAnswer:    strings.TrimSpace(a.Text),
		Working:          nonBlank(a.Working),
		TotalMarks:       q.TotalMarks,
		Reasons:          append([]string(nil), a.Notes...),
	}

	if res.StudentAnswer == "" {
		res.Method = MethodBlank
		res.NeedsReview = true
		res.Reasons = append(res.Reasons,
			"No answer was found for this question. Check the page reading before giving 0.")
		res.Steps = stepsFor(q, false, len(res.Working) > 0)
		finishSteps(&res)
		return res
	}

	best, found := bestCandidate(q, res.StudentAnswer)
	if !found {
		res.Method = MethodNone
		res.NeedsReview = true
		res.Reasons = append(res.Reasons, fmt.Sprintf(
			"%q is not an accepted answer or a known wrong answer in the scheme, so no mark was guessed.",
			res.StudentAnswer))
		res.Steps = stepsFor(q, false, len(res.Working) > 0)
		finishSteps(&res)
		return res
	}

	res.Method = best.method
	res.MatchedText = best.text
	res.MatchedAnswerID = best.answerID
	res.MisconceptionID = best.miscID
	res.LikelyCause = best.cause
	res.DraftMarks = math.Min(best.marks, q.TotalMarks)
	res.NeedsReview = best.needsReview
	res.Reasons = append(res.Reasons, best.reason)

	switch {
	case best.method == MethodMisconception:
		res.Steps = stepsFor(q, false, len(res.Working) > 0)
	case res.DraftMarks >= q.TotalMarks:
		res.Steps = stepsFor(q, true, false)
	default:
		res.Steps = variantSteps(q)
	}
	finishSteps(&res)
	return res
}

// MarkScript drafts every question of a scheme from the given answers.
// Answers for question numbers the scheme does not have are reported as
// unassigned, as is any text passed in unassigned.
func MarkScript(questions []domain.SchemeQuestion, answers []Answer, unassigned []string) Result {
	byNumber := map[int][]Answer{}
	for _, a := range answers {
		byNumber[a.QuestionNumber] = append(byNumber[a.QuestionNumber], a)
	}
	qs := append([]domain.SchemeQuestion(nil), questions...)
	sort.Slice(qs, func(i, j int) bool { return qs[i].QuestionNumber < qs[j].QuestionNumber })

	out := Result{Questions: []QuestionResult{}, Unassigned: append([]string{}, unassigned...)}
	known := map[int]bool{}
	for _, q := range qs {
		known[q.QuestionNumber] = true
		given := byNumber[q.QuestionNumber]
		var a Answer
		switch len(given) {
		case 0:
			a = Answer{QuestionNumber: q.QuestionNumber}
		case 1:
			a = given[0]
		default:
			// Two answers for one question: mark neither silently. Use the
			// last (a student's correction usually comes after), say so,
			// and send the earlier ones to review.
			a = given[len(given)-1]
			a.Notes = append(append([]string(nil), a.Notes...), fmt.Sprintf(
				"Question %d was answered %d times; the last answer was used.", q.QuestionNumber, len(given)))
			for _, g := range given[:len(given)-1] {
				out.Unassigned = append(out.Unassigned, fmt.Sprintf("Q%d (earlier answer): %s", q.QuestionNumber, g.Text))
			}
		}
		r := MarkQuestion(q, a)
		if len(given) > 1 {
			r.NeedsReview = true
		}
		out.Questions = append(out.Questions, r)
		out.DraftTotal += r.DraftMarks
		out.MaxTotal += q.TotalMarks
		if r.NeedsReview {
			out.NeedsReview++
		}
	}
	for _, a := range answers {
		if !known[a.QuestionNumber] {
			out.Unassigned = append(out.Unassigned,
				fmt.Sprintf("Q%d (not in the scheme): %s", a.QuestionNumber, a.Text))
		}
	}
	out.DraftTotal = round2(out.DraftTotal)
	out.MaxTotal = round2(out.MaxTotal)
	return out
}

// bestCandidate finds the most certain way to mark the answer.
func bestCandidate(q domain.SchemeQuestion, answer string) (candidate, bool) {
	var cands []candidate
	for _, aa := range q.AcceptedAnswers {
		if c, ok := compareAccepted(answer, aa); ok {
			cands = append(cands, c)
		}
	}
	for _, m := range q.Misconceptions {
		if c, ok := compareMisconception(answer, m); ok {
			cands = append(cands, c)
		}
	}
	if len(cands) == 0 {
		return candidate{}, false
	}
	// Most certain first; between equally certain matches, the higher mark —
	// and if they disagree, that is itself worth a teacher's look.
	sort.SliceStable(cands, func(i, j int) bool {
		if cands[i].rank != cands[j].rank {
			return cands[i].rank < cands[j].rank
		}
		return cands[i].marks > cands[j].marks
	})
	best := cands[0]
	for _, c := range cands[1:] {
		if c.rank == best.rank && c.marks != best.marks {
			best.needsReview = true
			best.reason += fmt.Sprintf(" It also matches %q (worth %s), so check which applies.", c.text, fmtMarks(c.marks))
			break
		}
	}
	return best, true
}

// Ranks: confident matches 0–2, misconceptions 3, flagged matches 4–6.
// A confident match on an accepted answer beats a misconception; a flagged
// one does not, because a teacher-named wrong answer is the more specific fit.
func compareAccepted(answer string, aa domain.AcceptedAnswer) (candidate, bool) {
	c := candidate{marks: aa.MarksAwarded, text: aa.AnswerText, answerID: aa.ID}
	accepted := strings.TrimSpace(aa.AnswerText)
	if accepted == "" {
		return c, false
	}
	worth := fmtMarks(aa.MarksAwarded)

	if answer == accepted {
		c.rank, c.method = 0, MethodExact
		c.reason = fmt.Sprintf("Matches the accepted answer %q exactly (worth %s).", accepted, worth)
		return c, true
	}
	na, nb := normalize(answer), normalize(accepted)
	if na == nb || (!hasDigit(na) && !hasDigit(nb) && wordsOnly(na) == wordsOnly(nb) && wordsOnly(na) != "") {
		c.rank, c.method = 1, MethodNormalized
		c.reason = fmt.Sprintf("Matches the accepted answer %q once case, spacing and punctuation are ignored (worth %s).", accepted, worth)
		return c, true
	}

	sa, okA := parseNumber(na)
	sb, okB := parseNumber(nb)
	if !okA || !okB {
		return c, false
	}
	if sa.value.Cmp(sb.value) == 0 {
		switch {
		case sa.unit != sb.unit:
			c.rank, c.method, c.needsReview = 5, MethodUnit, true
			c.reason = fmt.Sprintf("The number matches the accepted answer %q but the unit %s. Check whether the unit is required (worth %s if accepted).",
				accepted, unitDifference(sa.unit, sb.unit), worth)
		case sameWriting(sa, sb):
			c.rank, c.method = 2, MethodNumeric
			c.reason = fmt.Sprintf("The same number as the accepted answer %q (worth %s).", accepted, worth)
		default:
			c.rank, c.method, c.needsReview = 4, MethodEquivalent, true
			c.reason = fmt.Sprintf("Equal in value to the accepted answer %q but written as a %s rather than a %s. Check whether the question asks for a particular form (worth %s if accepted).",
				accepted, sa.form, sb.form, worth)
		}
		return c, true
	}
	if sa.unit == sb.unit {
		if places, ok := roundsTo(sa, sb); ok {
			c.rank, c.method, c.needsReview = 6, MethodRounded, true
			c.reason = fmt.Sprintf("Agrees with the accepted answer %q when rounded to %d decimal place(s). Check the precision the question asks for (worth %s if accepted).",
				accepted, places, worth)
			return c, true
		}
	}
	return c, false
}

func compareMisconception(answer string, m domain.Misconception) (candidate, bool) {
	c := candidate{rank: 3, method: MethodMisconception, marks: m.MarksAwarded,
		text: m.WrongAnswerPattern, miscID: m.ID, cause: m.LikelyCause}
	pattern := strings.TrimSpace(m.WrongAnswerPattern)
	if pattern == "" {
		return c, false
	}
	cause := ""
	if m.LikelyCause != "" {
		cause = " Likely cause: " + m.LikelyCause + "."
	}
	if normalize(answer) == normalize(pattern) {
		c.reason = fmt.Sprintf("Matches a known wrong answer in the scheme, given %s.%s", fmtMarks(m.MarksAwarded), cause)
		return c, true
	}
	// The editor saves patterns with every symbol stripped ("3/4" as "34"),
	// so this is the only comparison that can match them — and it cannot
	// tell "3/4" from "34". Proposed, but always for review.
	if lossyKey(answer) != "" && lossyKey(answer) == lossyKey(pattern) {
		c.rank, c.needsReview = 4, true
		c.reason = fmt.Sprintf("Looks like a known wrong answer in the scheme (pattern %q), given %s, but the scheme stores that pattern without its symbols, so check it.%s",
			pattern, fmtMarks(m.MarksAwarded), cause)
		return c, true
	}
	return c, false
}

// stepsFor lays out the breakdown when the answer was right (everything
// awarded) or not (final-answer steps lost; method steps open to judgement
// if working was shown).
func stepsFor(q domain.SchemeQuestion, correct, workingShown bool) []StepResult {
	out := make([]StepResult, 0, len(q.MarkBreakdown))
	for _, s := range q.MarkBreakdown {
		r := StepResult{StepID: s.ID, Type: s.Type, Criteria: s.Criteria, Marks: s.Marks}
		switch {
		case correct:
			r.Status, r.Awarded = StepAwarded, s.Marks
		case s.Type == "final_answer":
			r.Status = StepNotAwarded
		case workingShown:
			r.Status = StepNeedsReview
		default:
			r.Status = StepNotAwarded
		}
		out = append(out, r)
	}
	return out
}

func variantSteps(q domain.SchemeQuestion) []StepResult {
	out := make([]StepResult, 0, len(q.MarkBreakdown))
	for _, s := range q.MarkBreakdown {
		out = append(out, StepResult{StepID: s.ID, Type: s.Type, Criteria: s.Criteria,
			Marks: s.Marks, Status: StepByVariant})
	}
	return out
}

// finishSteps adds the review reasons the breakdown implies.
func finishSteps(r *QuestionResult) {
	var open float64
	for _, s := range r.Steps {
		if s.Status == StepNeedsReview {
			open += s.Marks
		}
	}
	if open > 0 && r.DraftMarks < r.TotalMarks {
		r.NeedsReview = true
		r.Reasons = append(r.Reasons, fmt.Sprintf(
			"Working is shown: up to %s method mark(s) need the teacher's judgement.", fmtMarks(math.Min(open, r.TotalMarks-r.DraftMarks))))
	}
	if r.Reasons == nil {
		r.Reasons = []string{}
	}
}

func unitDifference(student, accepted string) string {
	switch {
	case student == "":
		return fmt.Sprintf("is missing (expected %q)", accepted)
	case accepted == "":
		return fmt.Sprintf("%q was added", student)
	}
	return fmt.Sprintf("differs (%q, expected %q)", student, accepted)
}

func nonBlank(lines []string) []string {
	var out []string
	for _, l := range lines {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	return out
}

func round2(v float64) float64 { return math.Round(v*100) / 100 }

func fmtMarks(v float64) string {
	s := fmt.Sprintf("%.2f", v)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	if s == "1" {
		return "1 mark"
	}
	return s + " marks"
}
