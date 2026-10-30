package httpapi

import (
	"net/http"
	"strings"
	"testing"

	"solvanta/backend/internal/domain"
)

// The report card counts only the current term: last year's assessment and
// attendance must not move this term's averages or day counts.
func TestReportCardOnlyCountsCurrentTerm(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	eng, _ := st.AssessmentByID("ASSMT-ENG-T1")

	type card struct {
		Subjects []struct {
			SubjectID   string `json:"subjectId"`
			Assessments []struct {
				Title string `json:"title"`
			} `json:"assessments"`
		} `json:"subjects"`
		Attendance struct {
			TotalDays int `json:"totalDays"`
		} `json:"attendance"`
	}
	admin := login(t, r, "admin@solvanta.app", "admin123")
	var before card
	if code := getJSON(t, r, admin, "/api/reports/students/STU-001/report-card", &before); code != http.StatusOK {
		t.Fatalf("report card: %d", code)
	}

	old := eng
	old.ID, old.Title, old.Date = "ASSMT-ENG-OLD", "Last year's English test", "2025-10-01"
	if err := st.SaveAssessment(old); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveSubmission(domain.Submission{
		ID: "SUB-OLD", AssessmentID: old.ID, StudentID: "STU-001", ClassID: "JHS2A",
		Date: old.Date, Earned: 0,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveAttendance([]domain.AttendanceRecord{{
		ID: "ATT-OLD", StudentID: "STU-001", ClassID: "JHS2A", Date: "2025-10-01",
		Status: domain.AttAbsent,
	}}); err != nil {
		t.Fatal(err)
	}

	var after card
	getJSON(t, r, admin, "/api/reports/students/STU-001/report-card", &after)
	for _, s := range after.Subjects {
		for _, a := range s.Assessments {
			if a.Title == old.Title {
				t.Fatalf("last year's assessment leaked into this term's card")
			}
		}
	}
	if after.Attendance.TotalDays != before.Attendance.TotalDays {
		t.Fatalf("attendance days: got %d, want %d (last year's day counted)",
			after.Attendance.TotalDays, before.Attendance.TotalDays)
	}
}

// A teacher may export their own class's results but not another class's;
// school leaders may export any.
func TestClassResultsRestrictedToTeachersOwnClass(t *testing.T) {
	r, st := newTestServerWithStore(t, Config{})
	eng, _ := st.AssessmentByID("ASSMT-ENG-T1")
	other := eng
	other.ID, other.ClassID = "ASSMT-ENG-JHS1A", "JHS1A"
	if err := st.SaveAssessment(other); err != nil {
		t.Fatal(err)
	}

	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	if code := getJSON(t, r, teacher, "/api/reports/assessments/ASSMT-ENG-T1/class-results", nil); code != http.StatusOK {
		t.Fatalf("own class: got %d, want 200", code)
	}
	if code := getJSON(t, r, teacher, "/api/reports/assessments/ASSMT-ENG-JHS1A/class-results", nil); code != http.StatusForbidden {
		t.Fatalf("other class: got %d, want 403", code)
	}
	if code := getJSON(t, r, head, "/api/reports/assessments/ASSMT-ENG-JHS1A/class-results", nil); code != http.StatusOK {
		t.Fatalf("headteacher: got %d, want 200", code)
	}
}

func TestCSVFieldEscapesQuotesAndFormulas(t *testing.T) {
	for in, want := range map[string]string{
		`Ama Mensah`:             `"Ama Mensah"`,
		`Kofi "KB" Boateng`:      `"Kofi ""KB"" Boateng"`,
		`=HYPERLINK("http://x")`: `"'=HYPERLINK(""http://x"")"`,
		`+233 24 000`:            `"'+233 24 000"`,
		`@SUM(A1)`:               `"'@SUM(A1)"`,
		`-12.5`:                  `"-12.5"`,
		`-`:                      `"-"`,
	} {
		if got := csvField(in); got != want {
			t.Errorf("csvField(%q) = %s, want %s", in, got, want)
		}
	}
	if !strings.HasPrefix(csvField("\t=1+1"), `"'`) {
		t.Error("tab-led formula not neutralised")
	}
}
