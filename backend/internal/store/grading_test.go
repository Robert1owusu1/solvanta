package store

import (
	"testing"

	"solvanta/backend/internal/domain"
)

// Both stores keep one grading config per school and hand out copies.
func TestGradingConfigPerSchool(t *testing.T) {
	for name, st := range map[string]Store{"memory": NewUnseeded(), "postgres": nil} {
		t.Run(name, func(t *testing.T) {
			if st == nil {
				st = postgresTest(t)
			}
			if _, ok := st.GradingConfig("SCH-001"); ok {
				t.Fatal("no config saved yet, but one was found")
			}
			a := domain.DefaultGradingConfig("SCH-001")
			a.Schemes[0].ClassWeight, a.Schemes[0].ExamWeight = 40, 60
			a.UpdatedAt = "2026-10-29 10:00"
			b := domain.DefaultGradingConfig("SCH-002")
			if err := st.SaveGradingConfig(a); err != nil {
				t.Fatal(err)
			}
			if err := st.SaveGradingConfig(b); err != nil {
				t.Fatal(err)
			}
			got, ok := st.GradingConfig("SCH-001")
			if !ok || got.Schemes[0].ClassWeight != 40 || len(got.Schemes[0].Bands) != 9 {
				t.Fatalf("SCH-001: %+v", got)
			}
			if other, _ := st.GradingConfig("SCH-002"); other.Schemes[0].ClassWeight != 30 {
				t.Fatalf("SCH-002 picked up SCH-001's split: %+v", other.Schemes[0])
			}
			got.Schemes[0].Bands[0].Grade = "X"
			if again, _ := st.GradingConfig("SCH-001"); again.Schemes[0].Bands[0].Grade != "1" {
				t.Fatal("changing a returned config changed the stored one")
			}
			a.Schemes[0].ClassWeight, a.Schemes[0].ExamWeight = 50, 50
			if err := st.SaveGradingConfig(a); err != nil {
				t.Fatal(err)
			}
			if got, _ := st.GradingConfig("SCH-001"); got.Schemes[0].ClassWeight != 50 {
				t.Fatalf("re-save not applied: %+v", got.Schemes[0])
			}
		})
	}
}

func TestFinishedTermsPerSchool(t *testing.T) {
	for name, st := range map[string]Store{"memory": NewUnseeded(), "postgres": nil} {
		t.Run(name, func(t *testing.T) {
			if st == nil {
				st = postgresTest(t)
			}
			t2 := domain.FinishedTerm{SchoolTerm: domain.SchoolTerm{Year: "2026/2027", Name: "Term 2", Start: "2027-01-11", End: "2027-04-09"}, Grading: domain.DefaultGradingConfig("SCH-001")}
			t1 := domain.FinishedTerm{SchoolTerm: domain.SchoolTerm{Year: "2026/2027", Name: "Term 1", Start: "2026-09-07", End: "2026-12-18"}, Grading: domain.DefaultGradingConfig("SCH-001")}
			_ = st.SaveFinishedTerm("SCH-001", t2)
			_ = st.SaveFinishedTerm("SCH-001", t1)
			t1.End = "2026-12-19" // re-saved with a correction: replaces, not duplicates
			_ = st.SaveFinishedTerm("SCH-001", t1)
			got := st.FinishedTerms("SCH-001")
			if len(got) != 2 || got[0].Name != "Term 1" || got[0].End != "2026-12-19" || got[1].Name != "Term 2" {
				t.Fatalf("SCH-001: %+v", got)
			}
			if len(got[0].Grading.Schemes) != 1 {
				t.Fatalf("grading not kept: %+v", got[0].Grading)
			}
			if other := st.FinishedTerms("SCH-002"); len(other) != 0 {
				t.Fatalf("SCH-002 sees SCH-001's terms: %+v", other)
			}
		})
	}
}
