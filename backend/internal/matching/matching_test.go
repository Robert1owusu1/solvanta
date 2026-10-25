package matching

import (
	"strings"
	"testing"

	"solvanta/backend/internal/domain"
)

// fractionQuestion is "Simplify 3/4 + 1/6": 11/12 earns all 4 marks, the
// unsimplified 22/24 earns 3, and adding the tops and bottoms (4/10) is a
// named misconception worth 1. The misconception pattern is stored the way
// the scheme editor saves it — symbols stripped ("410").
func fractionQuestion() domain.SchemeQuestion {
	return domain.SchemeQuestion{
		ID: "SQ-1", QuestionNumber: 1, TotalMarks: 4,
		MarkBreakdown: []domain.MarkBreakdownStep{
			{ID: "step-1", Type: "method", Criteria: "Common denominator", Marks: 2},
			{ID: "step-2", Type: "final_answer", Criteria: "Correct simplified answer", Marks: 2},
		},
		AcceptedAnswers: []domain.AcceptedAnswer{
			{ID: 11, AnswerText: "11/12", MarksAwarded: 4, IsPrimary: true},
			{ID: 12, AnswerText: "22/24", MarksAwarded: 3},
		},
		Misconceptions: []domain.Misconception{
			{ID: 21, WrongAnswerPattern: "410", LikelyCause: "Added numerators and denominators", MarksAwarded: 1},
		},
	}
}

func decimalQuestion() domain.SchemeQuestion {
	return domain.SchemeQuestion{
		ID: "SQ-2", QuestionNumber: 2, TotalMarks: 2,
		MarkBreakdown:   []domain.MarkBreakdownStep{{ID: "step-1", Type: "final_answer", Marks: 2}},
		AcceptedAnswers: []domain.AcceptedAnswer{{ID: 31, AnswerText: "0.375 m", MarksAwarded: 2, IsPrimary: true}},
	}
}

func wordQuestion() domain.SchemeQuestion {
	return domain.SchemeQuestion{
		ID: "SQ-3", QuestionNumber: 3, TotalMarks: 1,
		MarkBreakdown:   []domain.MarkBreakdownStep{{ID: "step-1", Type: "final_answer", Marks: 1}},
		AcceptedAnswers: []domain.AcceptedAnswer{{ID: 41, AnswerText: "Photosynthesis", MarksAwarded: 1, IsPrimary: true}},
	}
}

func TestMatchLevels(t *testing.T) {
	cases := []struct {
		name        string
		q           domain.SchemeQuestion
		answer      string
		method      Method
		marks       float64
		needsReview bool
	}{
		{"exact", fractionQuestion(), "11/12", MethodExact, 4, false},
		{"spacing and full stop", fractionQuestion(), " 11 / 12. ", MethodNormalized, 4, false},
		{"unicode fraction slash", fractionQuestion(), "11⁄12", MethodNormalized, 4, false},
		{"partial-credit variant", fractionQuestion(), "22/24", MethodExact, 3, false},
		{"rounded decimal of a fraction is flagged", fractionQuestion(), "0.9167", MethodRounded, 4, true},
		{"decimal for a fraction is flagged", decimalQuestion(), "3/8 m", MethodEquivalent, 2, true},
		{"trailing zero is the same number", decimalQuestion(), "0.3750 m", MethodNumeric, 2, false},
		{"missing unit is flagged", decimalQuestion(), "0.375", MethodUnit, 2, true},
		{"rounded is flagged", decimalQuestion(), "0.38 m", MethodRounded, 2, true},
		{"word answer, case", wordQuestion(), "photosynthesis", MethodNormalized, 1, false},
		{"word answer, punctuation", wordQuestion(), "Photosynthesis!", MethodNormalized, 1, false},
		{"misconception via stored pattern", fractionQuestion(), "4/10", MethodMisconception, 1, true},
		{"not in the scheme", fractionQuestion(), "5/6", MethodNone, 0, true},
		{"blank", fractionQuestion(), "   ", MethodBlank, 0, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := MarkQuestion(tc.q, Answer{QuestionNumber: tc.q.QuestionNumber, Text: tc.answer})
			if r.Method != tc.method || r.DraftMarks != tc.marks || r.NeedsReview != tc.needsReview {
				t.Fatalf("got method=%s marks=%v review=%v, want %s %v %v\nreasons: %v",
					r.Method, r.DraftMarks, r.NeedsReview, tc.method, tc.marks, tc.needsReview, r.Reasons)
			}
			if len(r.Reasons) == 0 {
				t.Error("no reason given for the mark")
			}
		})
	}
}

// TestSymbolsAreNeverDiscarded is the guard against the editor's lossy
// normalizer: "12" must not earn the marks for "1/2", nor "15" for "1.5".
func TestSymbolsAreNeverDiscarded(t *testing.T) {
	q := domain.SchemeQuestion{QuestionNumber: 1, TotalMarks: 2,
		AcceptedAnswers: []domain.AcceptedAnswer{
			{AnswerText: "1/2", NormalizedForm: "12", MarksAwarded: 2, IsPrimary: true},
			{AnswerText: "1.5", NormalizedForm: "15", MarksAwarded: 2},
			{AnswerText: "-3", NormalizedForm: "3", MarksAwarded: 2},
		}}
	for _, wrong := range []string{"12", "15", "3"} {
		r := MarkQuestion(q, Answer{Text: wrong})
		if r.DraftMarks != 0 || r.Method != MethodNone {
			t.Errorf("%q earned %v via %s; symbols were discarded", wrong, r.DraftMarks, r.Method)
		}
	}
}

// A misconception named with its symbols intact is a confident match.
func TestMisconceptionWithFullPatternIsConfident(t *testing.T) {
	q := fractionQuestion()
	q.Misconceptions[0].WrongAnswerPattern = "4/10"
	r := MarkQuestion(q, Answer{Text: "4/10"})
	if r.Method != MethodMisconception || r.DraftMarks != 1 || r.NeedsReview || r.LikelyCause == "" {
		t.Fatalf("got %+v", r)
	}
}

func TestBreakdownSteps(t *testing.T) {
	q := fractionQuestion()

	right := MarkQuestion(q, Answer{Text: "11/12"})
	for _, s := range right.Steps {
		if s.Status != StepAwarded || s.Awarded != s.Marks {
			t.Errorf("correct answer, step %s: %+v", s.StepID, s)
		}
	}

	// Wrong with working shown: final-answer step lost, method step left to
	// the teacher, and the question flagged with the marks still open.
	wrong := MarkQuestion(q, Answer{Text: "5/6", Working: []string{"9/12 + 2/12"}})
	if wrong.Steps[0].Status != StepNeedsReview || wrong.Steps[1].Status != StepNotAwarded {
		t.Errorf("wrong with working: %+v", wrong.Steps)
	}
	if !strings.Contains(strings.Join(wrong.Reasons, " "), "up to 2 marks") {
		t.Errorf("reasons should name the open method marks: %v", wrong.Reasons)
	}

	// Wrong with no working: nothing to judge, nothing awarded.
	bare := MarkQuestion(q, Answer{Text: "5/6"})
	for _, s := range bare.Steps {
		if s.Status != StepNotAwarded || s.Awarded != 0 {
			t.Errorf("wrong without working, step %s: %+v", s.StepID, s)
		}
	}

	// A partial-credit variant sets the question's marks; the scheme does
	// not say which steps it covers, so none are claimed.
	partial := MarkQuestion(q, Answer{Text: "22/24"})
	for _, s := range partial.Steps {
		if s.Status != StepByVariant || s.Awarded != 0 {
			t.Errorf("partial variant, step %s: %+v", s.StepID, s)
		}
	}
}

func TestMarksNeverExceedTheTotal(t *testing.T) {
	q := fractionQuestion()
	q.AcceptedAnswers[0].MarksAwarded = 9
	if r := MarkQuestion(q, Answer{Text: "11/12"}); r.DraftMarks != 4 {
		t.Errorf("draft = %v, want capped at 4", r.DraftMarks)
	}
}

func TestMarkScript(t *testing.T) {
	scheme := []domain.SchemeQuestion{decimalQuestion(), fractionQuestion(), wordQuestion()}
	answers := []Answer{
		{QuestionNumber: 1, Text: "11/12"},
		{QuestionNumber: 2, Text: "0.375 m"},
		{QuestionNumber: 2, Text: "0.5 m"},
		{QuestionNumber: 9, Text: "stray"},
	}
	r := MarkScript(scheme, answers, []string{"Name: Kojo"})

	if r.Final {
		t.Fatal("a draft must never be final")
	}
	if len(r.Questions) != 3 || r.Questions[0].QuestionNumber != 1 || r.Questions[2].QuestionNumber != 3 {
		t.Fatalf("questions out of order: %+v", r.Questions)
	}
	// Q2 answered twice: the last answer is used, and it is flagged.
	q2 := r.Questions[1]
	if q2.StudentAnswer != "0.5 m" || !q2.NeedsReview {
		t.Errorf("duplicate answer: %+v", q2)
	}
	// Q3 never answered: blank and flagged.
	if r.Questions[2].Method != MethodBlank || !r.Questions[2].NeedsReview {
		t.Errorf("missing answer: %+v", r.Questions[2])
	}
	if r.DraftTotal != 4 || r.MaxTotal != 7 || r.NeedsReview != 2 {
		t.Errorf("totals: draft %v / %v, %d flagged; want 4 / 7, 2 flagged", r.DraftTotal, r.MaxTotal, r.NeedsReview)
	}
	joined := strings.Join(r.Unassigned, " | ")
	for _, want := range []string{"Name: Kojo", "Q9 (not in the scheme): stray", "Q2 (earlier answer): 0.375 m"} {
		if !strings.Contains(joined, want) {
			t.Errorf("unassigned should include %q: %v", want, r.Unassigned)
		}
	}
}

func TestParseNumber(t *testing.T) {
	cases := []struct {
		in    string
		value string
		form  form
		unit  string
		ok    bool
	}{
		{"0.75", "3/4", formDecimal, "", true},
		{".5", "1/2", formDecimal, "", true},
		{"3/4", "3/4", formFraction, "", true},
		{"-3/4", "-3/4", formFraction, "", true},
		{"1 1/2", "3/2", formMixed, "", true},
		{"75%", "3/4", formPercent, "", true},
		{"1,000", "1000", formDecimal, "", true},
		{"3/8 m", "3/8", formFraction, "m", true},
		{"60 km/h", "60", formDecimal, "km/h", true},
		{"gh₵5.50", "11/2", formDecimal, "ghs", true},
		{"x+3", "", 0, "", false},
		{"1 2", "", 0, "", false},
		{"3/0", "", 0, "", false},
		{"photosynthesis", "", 0, "", false},
	}
	for _, tc := range cases {
		n, ok := parseNumber(normalize(tc.in))
		if ok != tc.ok {
			t.Errorf("%q: ok=%v, want %v", tc.in, ok, tc.ok)
			continue
		}
		if !ok {
			continue
		}
		if n.value.RatString() != tc.value || n.form != tc.form || n.unit != tc.unit {
			t.Errorf("%q: got %s %s %q, want %s %s %q", tc.in, n.value.RatString(), n.form, n.unit, tc.value, tc.form, tc.unit)
		}
	}
}

func TestSplitAnswers(t *testing.T) {
	page := strings.Join([]string{
		"Name: Kojo Owusu",
		"1. 3/4 + 1/6",
		"9/12 + 2/12",
		"= 11/12",
		"Q2) 0.375 m",
		"Question 3: Photosynthesis",
		"4.",
		"3.5 cm",
		"0.5",
		"5) 2 + 2 = 4",
		"6. Ans: 12",
		"working after the answer",
	}, "\n")
	answers, unassigned := SplitAnswers(page, 0)

	if len(unassigned) != 1 || unassigned[0] != "Name: Kojo Owusu" {
		t.Errorf("unassigned = %v", unassigned)
	}
	want := map[int]string{1: "11/12", 2: "0.375 m", 3: "Photosynthesis", 4: "0.5", 5: "4", 6: "12"}
	if len(answers) != len(want) {
		t.Fatalf("got %d answers: %+v", len(answers), answers)
	}
	for _, a := range answers {
		if a.Text != want[a.QuestionNumber] {
			t.Errorf("Q%d = %q, want %q", a.QuestionNumber, a.Text, want[a.QuestionNumber])
		}
	}
	// "3.5 cm" and "0.5" are not question markers: Q4's working keeps 3.5 cm.
	if got := strings.Join(answers[3].Working, "|"); got != "3.5 cm" {
		t.Errorf("Q4 working = %q", got)
	}
	// Q6's answer is labelled, so the line after it stays as working.
	if got := strings.Join(answers[5].Working, "|"); got != "working after the answer" {
		t.Errorf("Q6 working = %q", got)
	}
	// How Q4's answer was chosen is recorded.
	if len(answers[3].Notes) == 0 {
		t.Error("Q4 should note that the last line was used")
	}
}

func TestSplitWithoutMarkers(t *testing.T) {
	answers, unassigned := SplitAnswers("11/12", 0)
	if len(answers) != 0 || len(unassigned) != 1 {
		t.Errorf("no markers, multi-question: answers=%v unassigned=%v", answers, unassigned)
	}
	answers, unassigned = SplitAnswers("9/12 + 2/12 = 11/12", 1)
	if len(answers) != 1 || answers[0].Text != "11/12" || len(unassigned) != 0 || len(answers[0].Notes) == 0 {
		t.Errorf("no markers, single question: answers=%+v unassigned=%v", answers, unassigned)
	}
}
