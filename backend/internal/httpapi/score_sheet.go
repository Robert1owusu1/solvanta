package httpapi

import (
	"net/http"
	"sort"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// scoreSheetReport is the gradebook for one class and subject in one term:
// students as rows, assessments as columns, each cell the score out of the
// assessment's effective total and marked AI / Manual / Absent, plus a weighted
// term total (the school's class-score/exam split and grade bands) and the
// student's position in the class.
//
// GET /api/reports/score-sheet?classId=&subjectId=&term=
// Same RBAC as classResultsReport: leaders and staff any class, a teacher only
// their own.
func (s *Server) scoreSheetReport(c *gin.Context) {
	classID := c.Query("classId")
	subjectID := c.Query("subjectId")
	if classID == "" || subjectID == "" {
		fail(c, http.StatusBadRequest, "classId and subjectId are required")
		return
	}
	if !validSubject(subjectID) {
		fail(c, http.StatusBadRequest, "Unknown subjectId")
		return
	}
	if _, ok := s.db(c).ClassByID(classID); !ok {
		fail(c, http.StatusNotFound, "Class not found")
		return
	}
	if !mayWorkOnClass(currentUser(c), classID) {
		fail(c, http.StatusForbidden, "You may only view your own class's score sheet")
		return
	}

	// Resolve the term window and the grading config in force for it. A named
	// finished term carries its own frozen grading; otherwise the current term
	// uses the school's live config.
	cur := s.db(c).Term()
	window := cur
	isCurrent := true
	school := s.gradingSchool(c)
	grading, ok := s.db(c).GradingConfig(school)
	if !ok {
		grading = domain.DefaultGradingConfig(school)
	}
	if term := c.Query("term"); term != "" && term != cur.Name {
		for _, ft := range s.db(c).FinishedTerms(school) {
			if ft.Name == term {
				window = ft.SchoolTerm
				grading = ft.Grading
				isCurrent = false
				break
			}
		}
	}
	scheme := grading.SchemeFor(classID, s.db(c).Classes())

	// Columns: the class+subject assessments in the term window. An undated
	// assessment counts as the current term's (matching the report card).
	var cols []domain.Assessment
	for _, a := range s.db(c).Assessments() {
		if a.ClassID != classID || a.SubjectID != subjectID {
			continue
		}
		inTerm := false
		if a.Date == "" {
			inTerm = isCurrent
		} else {
			inTerm = window.Contains(a.Date)
		}
		if typ := c.Query("type"); typ != "" && a.Type != typ {
			inTerm = false
		}
		if inTerm {
			cols = append(cols, a)
		}
	}
	sort.Slice(cols, func(i, j int) bool {
		if cols[i].Date != cols[j].Date {
			return cols[i].Date < cols[j].Date
		}
		return cols[i].ID < cols[j].ID
	})

	type cell struct {
		AssessmentID string  `json:"assessmentId"`
		Present      bool    `json:"present"`
		Earned       float64 `json:"earned"`
		Total        float64 `json:"total"`
		Percent      float64 `json:"percent"`
		Source       string  `json:"source,omitempty"`
		Absent       bool    `json:"absent"`
	}
	type rowOut struct {
		Student   domain.Student `json:"student"`
		Cells     []cell         `json:"cells"`
		HasTotal  bool           `json:"hasTotal"`
		TermTotal float64        `json:"termTotal"`
		Grade     string         `json:"grade"`
		Position  int            `json:"position"` // 0 = no total, not ranked
	}

	colMeta := make([]gin.H, 0, len(cols))
	for _, a := range cols {
		colMeta = append(colMeta, gin.H{
			"id": a.ID, "title": a.Title, "type": a.Type,
			"date": a.Date, "total": a.EffectiveTotal(), "isExam": domain.IsExamType(a.Type),
		})
	}

	var rows []rowOut
	for _, st := range s.db(c).Students() {
		if st.ClassID != classID {
			continue
		}
		cells := make([]cell, 0, len(cols))
		var classSum, examSum float64
		var classN, examN int
		for _, a := range cols {
			sub, found := s.db(c).SubmissionFor(a.ID, st.ID)
			if !found {
				cells = append(cells, cell{AssessmentID: a.ID, Present: false, Total: a.EffectiveTotal()})
				continue
			}
			total := a.EffectiveTotal()
			if sub.Absent {
				cells = append(cells, cell{AssessmentID: a.ID, Present: true, Total: total,
					Absent: true, Source: sub.EffectiveSource()})
				continue
			}
			pct := 0.0
			if total > 0 {
				pct = 100 * sub.Earned / total
			}
			cells = append(cells, cell{AssessmentID: a.ID, Present: true, Earned: sub.Earned,
				Total: total, Percent: pct, Source: sub.EffectiveSource()})
			if domain.IsExamType(a.Type) {
				examSum += pct
				examN++
			} else {
				classSum += pct
				classN++
			}
		}
		total, has := weightedTotal(scheme, classSum, classN, examSum, examN)
		r := rowOut{Student: st, Cells: cells, HasTotal: has}
		if has {
			r.TermTotal = total
			r.Grade = scheme.BandFor(total).Grade
		}
		rows = append(rows, r)
	}

	assignPositions(len(rows), func(i int) (float64, bool) { return rows[i].TermTotal, rows[i].HasTotal },
		func(i, pos int) { rows[i].Position = pos })

	sendJSON(c, gin.H{
		"classId":     classID,
		"subjectId":   subjectID,
		"subject":     domain.SubjectName(subjectID),
		"term":        window,
		"scheme":      gin.H{"name": scheme.Name, "classWeight": scheme.ClassWeight, "examWeight": scheme.ExamWeight},
		"assessments": colMeta,
		"rows":        rows,
	})
}

// weightedTotal applies the class-score/exam split. With both buckets it is the
// weighted mean; with only one it is that bucket's average, so a term with no
// exam yet still shows a running total. Absent scores were already excluded by
// the caller. has is false when the student has no counted score at all.
func weightedTotal(scheme domain.GradingScheme, classSum float64, classN int, examSum float64, examN int) (float64, bool) {
	switch {
	case classN > 0 && examN > 0:
		classAvg := classSum / float64(classN)
		examAvg := examSum / float64(examN)
		return classAvg*scheme.ClassWeight/100 + examAvg*scheme.ExamWeight/100, true
	case classN > 0:
		return classSum / float64(classN), true
	case examN > 0:
		return examSum / float64(examN), true
	default:
		return 0, false
	}
}

// assignPositions ranks n rows by a score (descending), giving tied scores the
// same position and leaving rows without a total unranked (position 0). It does
// not reorder the rows.
func assignPositions(n int, score func(i int) (float64, bool), set func(i, pos int)) {
	type idx struct {
		i   int
		val float64
	}
	var ranked []idx
	for i := 0; i < n; i++ {
		if v, ok := score(i); ok {
			ranked = append(ranked, idx{i, v})
		}
	}
	sort.Slice(ranked, func(a, b int) bool { return ranked[a].val > ranked[b].val })
	pos := 0
	var prev float64
	for rank, r := range ranked {
		if rank == 0 || r.val != prev {
			pos = rank + 1
			prev = r.val
		}
		set(r.i, pos)
	}
}
