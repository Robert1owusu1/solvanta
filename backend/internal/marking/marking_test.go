package marking

import (
	"testing"

	"solvanta/backend/internal/domain"
)

func TestComputeEarned(t *testing.T) {
	qs := []domain.Question{
		{ID: "q1", Type: domain.QTypeMCQ, Marks: 2, CorrectAnswer: "2/4"},
		{ID: "q2", Type: domain.QTypeTrueFalse, Marks: 1, CorrectAnswer: "True"},
		{ID: "q3", Type: domain.QTypeMath, Marks: 4}, // teacher-marked
	}
	subjective := []domain.Question{qs[2]}

	tests := []struct {
		name         string
		answers      map[string]string
		teacherMarks map[string]float64
		want         float64
	}{
		{"all correct objective, auto only", map[string]string{"q1": " 2/4 ", "q2": "true"}, nil, 3},
		{"case/whitespace insensitive", map[string]string{"q1": "2/4", "q2": "TRUE"}, map[string]float64{}, 3},
		{"wrong answers earn zero", map[string]string{"q1": "2/3", "q2": "False"}, nil, 0.0},
		{"math uses teacher mark", map[string]string{"q1": "2/4", "q2": "True"}, map[string]float64{"q3": 3}, 6},
		{"subjective without mark", map[string]string{}, map[string]float64{}, 0},
		// A finalized review records the teacher's decision on every question.
		{"teacher mark overrides a wrong MCQ", map[string]string{"q1": "2/3", "q2": "True"}, map[string]float64{"q1": 1}, 2},
		{"teacher mark overrides a right MCQ", map[string]string{"q1": "2/4", "q2": "True"}, map[string]float64{"q1": 0}, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			q := append([]domain.Question(nil), qs...)
			got := ComputeEarned(q, tt.answers, tt.teacherMarks)
			if got != tt.want {
				t.Fatalf("ComputeEarned = %v, want %v", got, tt.want)
			}
		})
	}
	t.Run("subjective list", func(t *testing.T) {
		if got := ComputeEarned(subjective, nil, map[string]float64{"q3": 2}); got != 2 {
			t.Fatalf("subjective earned = %v, want 2", got)
		}
	})
}

func TestGradeLetter(t *testing.T) {
	tests := []struct {
		pct  float64
		want string
	}{
		{100, "A"}, {85, "A"}, {84.9, "B"}, {70, "B"}, {69, "C"}, {60, "C"},
		{59.9, "D"}, {50, "D"}, {49.9, "F"}, {0, "F"},
	}
	for _, tt := range tests {
		if got := GradeLetter(tt.pct); got != tt.want {
			t.Fatalf("GradeLetter(%v) = %v, want %v", tt.pct, got, tt.want)
		}
	}
}

func TestNumericEquivalence(t *testing.T) {
	eq := []struct{ a, b string }{
		{"3/4", "0.75"}, {"3/4", "75%"}, {"1/2", "0.5"}, {"2/4", "1/2"},
		{"11/12", "0.9166666666"},
	}
	for _, e := range eq {
		if !NumericEquivalence(e.a, e.b) {
			t.Fatalf("%q ≠ %q", e.a, e.b)
		}
	}
	if NumericEquivalence("goes", "go") {
		t.Fatal("non-numeric strings must not be numeric-equivalent")
	}
}

func TestBlueprintPickByTopic(t *testing.T) {
	bank := []domain.Question{
		{ID: "1", SubjectID: "MATH", Topic: "Fractions"},
		{ID: "2", SubjectID: "MATH", Topic: "Fractions"},
		{ID: "3", SubjectID: "MATH", Topic: "Fractions"},
		{ID: "4", SubjectID: "MATH", Topic: "Algebra"},
		{ID: "5", SubjectID: "ENG", Topic: "Grammar"},
	}
	picked := BlueprintPick(bank, "Fractions", "MATH", 2)
	if len(picked) != 2 {
		t.Fatalf("picked %d, want 2", len(picked))
	}
	for i := 1; i < len(picked); i++ {
		if picked[i].ID == picked[0].ID {
			t.Fatal("duplicate pick")
		}
	}
	// insufficient topic pool → falls back to subject
	fallback := BlueprintPick(bank, "Algebra", "ENG", 5)
	if len(fallback) != 1 || fallback[0].SubjectID != "ENG" {
		t.Fatalf("fallback failed: %+v", fallback)
	}
}

func TestWeakTopicsThreshold(t *testing.T) {
	qs := []domain.Question{
		{ID: "a", Type: domain.QTypeMCQ, Topic: "Fractions", CorrectAnswer: "x"},
	}
	assessments := []domain.Assessment{
		{ID: "A1", SubjectID: "MATH", Questions: qs},
	}
	correct := map[string]string{"a": "x"}
	wrong := map[string]string{"a": "y"}
	subs := []domain.Submission{
		{AssessmentID: "A1", StudentID: "S1", Answers: correct},
		{AssessmentID: "A1", StudentID: "S1", Answers: wrong},
	}
	topics := WeakTopics("S1", assessments, subs)
	if len(topics) != 1 || topics[0].Correct != 1 || topics[0].Total != 2 {
		t.Fatalf("unexpected weak topics: %+v", topics)
	}
	if topics[0].Pct != 50 {
		t.Fatalf("pct = %v, want 50", topics[0].Pct)
	}
}

func TestClassPerformanceGapsAndAtRisk(t *testing.T) {
	qs := []domain.Question{
		{ID: "q1", Type: domain.QTypeMCQ, Topic: "Fractions", CorrectAnswer: "a", Marks: 2},
	}
	assessments := []domain.Assessment{{ID: "A1", SubjectID: "MATH", ClassID: "JHS2A", Questions: qs}}
	students := []domain.Student{{ID: "S1", ClassID: "JHS2A"}, {ID: "S2", ClassID: "JHS2A"}}
	subs := []domain.Submission{
		{AssessmentID: "A1", StudentID: "S1", ClassID: "JHS2A", Answers: map[string]string{"q1": "a"}, Earned: 2},
		{AssessmentID: "A1", StudentID: "S2", ClassID: "JHS2A", Answers: map[string]string{"q1": "b"}, Earned: 0},
	}
	cp := ClassPerformance{Assessments: assessments, Subs: subs, Students: students}

	if avg := cp.AssessmentAverage(assessments[0]); avg != 0.5 {
		t.Fatalf("average = %v, want 0.5", avg)
	}
	gaps := cp.Gaps(assessments[0])
	if len(gaps) != 1 || gaps[0].CorrectRate != 0.5 || gaps[0].Gap != 0.5 {
		t.Fatalf("gaps = %+v", gaps)
	}
	risk := cp.AtRisk(60)
	if len(risk) != 1 || risk[0].Student.ID != "S2" {
		t.Fatalf("at-risk = %+v", risk)
	}
	if risk[0].SuggestedIntervention != "Re-teach & practice on Fractions; reassess in 2 weeks" {
		t.Fatalf("intervention text = %q", risk[0].SuggestedIntervention)
	}
}
