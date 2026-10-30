package httpapi

import (
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/marking"
)

// studentReportCard mirrors reporting_service report-card structure: per-subject
// rows plus overall average and attendance (doc §22, §34).
func (s *Server) studentReportCard(c *gin.Context) {
	st, ok := s.store.StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}

	type assessmentRow struct {
		Title   string  `json:"title"`
		Type    string  `json:"type"`
		Date    string  `json:"date"`
		Marks   float64 `json:"marks"`
		Total   float64 `json:"total"`
		Percent float64 `json:"percent"`
		Grade   string  `json:"grade"`
	}
	type subjectRow struct {
		SubjectID   string          `json:"subjectId"`
		SubjectName string          `json:"subjectName"`
		Assessments []assessmentRow `json:"assessments"`
		Average     float64         `json:"average"`
		Grade       string          `json:"grade"`
	}

	// Only this term's work and days count; undated assessments are taken as
	// this term's, matching the app's report card.
	term := s.store.Term()
	perSubject := map[string][]assessmentRow{}
	for _, a := range s.store.Assessments() {
		if a.ClassID != st.ClassID || (a.Date != "" && !term.Contains(a.Date)) {
			continue
		}
		sub, found := s.store.SubmissionFor(a.ID, st.ID)
		if !found {
			continue
		}
		total := a.TotalMarks()
		pct := 0.0
		if total > 0 {
			pct = 100 * sub.Earned / total
		}
		perSubject[a.SubjectID] = append(perSubject[a.SubjectID], assessmentRow{
			Title: a.Title, Type: a.Type, Date: a.Date,
			Marks: sub.Earned, Total: total, Percent: pct, Grade: marking.GradeLetter(pct),
		})
	}

	var subjects []subjectRow
	var overallSum, overallN float64
	for _, s2 := range domain.Subjects {
		rows := perSubject[s2.ID]
		if len(rows) == 0 {
			continue
		}
		avg := 0.0
		for _, r := range rows {
			avg += r.Percent
		}
		avg /= float64(len(rows))
		overallSum += avg
		overallN++
		subjects = append(subjects, subjectRow{
			SubjectID: s2.ID, SubjectName: s2.Name, Assessments: rows, Average: avg, Grade: marking.GradeLetter(avg),
		})
	}
	overallAvg := 0.0
	if overallN > 0 {
		overallAvg = overallSum / overallN
	}

	counts := map[string]int{}
	var totalDays int
	for _, r := range s.store.Attendance() {
		if r.StudentID == st.ID && term.Contains(r.Date) {
			counts[r.Status]++
			totalDays++
		}
	}
	attPct := 0.0
	if totalDays > 0 {
		attPct = 100 * float64(counts[domain.AttPresent]+counts[domain.AttLate]) / float64(totalDays)
	}

	sendJSON(c, gin.H{
		"student":    st,
		"term":       term,
		"subjects":   subjects,
		"overall":    gin.H{"average": overallAvg, "grade": marking.GradeLetter(overallAvg)},
		"attendance": gin.H{"present": counts[domain.AttPresent], "late": counts[domain.AttLate], "absent": counts[domain.AttAbsent], "excused": counts[domain.AttExcused], "totalDays": totalDays, "percentage": attPct},
	})
}

// classResultsReport exports an assessment's results in rows for CSV/Excel/PDF
// generation (doc §33, §34).
// classResultRow is one line of an exported class-results report.
type classResultRow struct {
	StudentID string  `json:"studentId"`
	Name      string  `json:"name"`
	Class     string  `json:"class"`
	Marks     float64 `json:"marks"`
	Total     float64 `json:"total"`
	Percent   float64 `json:"percent"`
	Grade     string  `json:"grade"`
}

func (s *Server) classResultsReport(c *gin.Context) {
	a, ok := s.store.AssessmentByID(c.Param("id"))
	if !ok {
		fail(c, http.StatusNotFound, "Assessment not found")
		return
	}
	if !teacherCoversClass(currentUser(c), a.ClassID) {
		fail(c, http.StatusForbidden, "You may only view your own class's results")
		return
	}
	total := a.TotalMarks()
	var rows []classResultRow
	for _, st := range s.store.Students() {
		sub, found := s.store.SubmissionFor(a.ID, st.ID)
		if !found {
			continue
		}
		pct := 0.0
		if total > 0 {
			pct = 100 * sub.Earned / total
		}
		rows = append(rows, classResultRow{StudentID: st.ID, Name: st.FullName(), Class: st.ClassID, Marks: sub.Earned, Total: total, Percent: pct, Grade: marking.GradeLetter(pct)})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Percent > rows[j].Percent })
	sendJSON(c, gin.H{
		"assessment": a,
		"rows":       rows,
		"totalMarks": total,
		"csv":        renderCSV(a, rows),
	})
}

// renderCSV produces a plain-text CSV body clients export directly.
func renderCSV(a domain.Assessment, rows []classResultRow) string {
	b := "Assessment,Subject,Class\n"
	b += csvField(a.Title) + "," + csvField(a.SubjectID) + "," + csvField(a.ClassID) + "\n\n"
	b += "Name,Class,Marks,Total,Percent(%),Grade\n"
	for _, r := range rows {
		b += csvField(r.Name) + "," + csvField(r.Class) + "," +
			itoa(int(r.Marks)) + "," + itoa(int(r.Total)) + "," +
			itoa(int(r.Percent)) + "," + csvField(r.Grade) + "\n"
	}
	return b
}

// csvField quotes s for CSV, doubling embedded quotes. Text a spreadsheet
// would run as a formula (=, +, -, @, tab or CR first — e.g. a student named
// =HYPERLINK(...)) gets a leading ' so it opens as plain text.
func csvField(s string) string {
	if len(s) > 1 && strings.ContainsRune("=+-@\t\r", rune(s[0])) {
		if _, err := strconv.ParseFloat(s, 64); err != nil {
			s = "'" + s
		}
	}
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}
