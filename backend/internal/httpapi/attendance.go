package httpapi

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gin-gonic/gin/binding"

	"solvanta/backend/internal/domain"
)

// attendanceForClassDate returns the day's records (doc §12). Non-staff users
// may only read their own class.
func (s *Server) attendanceForClassDate(c *gin.Context) {
	u := currentUser(c)
	classID := c.Param("classId")
	if !u.IsSchoolStaff() && !s.viewsClass(c, u, classID) {
		fail(c, http.StatusForbidden, "You may only view your own class attendance")
		return
	}
	date := c.Param("date")
	days := s.db(c).AttendanceForClassDate(classID, date)
	name := u.Name
	sendJSON(c, domain.AttendanceDay{Date: date, ClassID: classID, MarkedBy: name, Records: days})
}

// saveAttendanceDay replaces one day's records for one class. The request may
// be either a bare record list or {"records": [...]}.
func (s *Server) saveAttendanceDay(c *gin.Context) {
	classID := c.Param("classId")
	date := c.Param("date")

	var wrapper struct {
		Records []domain.AttendanceRecord `json:"records"`
	}
	var raw []domain.AttendanceRecord
	// Either {"records": [...]} or a bare list. ShouldBindBodyWith keeps the
	// body for the second attempt (ShouldBindJSON would have consumed it).
	if err := c.ShouldBindBodyWith(&wrapper, binding.JSON); err == nil && wrapper.Records != nil {
		raw = wrapper.Records
	} else if err := c.ShouldBindBodyWith(&raw, binding.JSON); err != nil {
		fail(c, http.StatusBadRequest, "Invalid attendance body")
		return
	}
	for i := range raw {
		raw[i].ClassID = classID
		if raw[i].Date == "" {
			raw[i].Date = date
		}
		if raw[i].ID == "" {
			raw[i].ID = newID("ATT")
		}
	}
	before := map[string]string{}
	for _, r := range s.db(c).AttendanceForClassDate(classID, date) {
		before[r.StudentID] = r.Status
	}
	if writeFailed(c, s.db(c).SaveDay(classID, date, raw)) {
		return
	}
	// Tell parents about a new absence or late arrival — only on a change,
	// so re-saving the same roll doesn't repeat the notice.
	for _, r := range raw {
		if (r.Status != domain.AttAbsent && r.Status != domain.AttLate) || before[r.StudentID] == r.Status {
			continue
		}
		st, ok := s.db(c).StudentByID(r.StudentID)
		if !ok || st.ParentUserID == "" {
			continue
		}
		word := "absent"
		if r.Status == domain.AttLate {
			word = "late"
		}
		s.notify(c, st.ParentUserID, domain.NotifAttendance, st.FullName()+" "+word,
			st.FullName()+" was marked "+word+" on "+date+".", st.ID)
	}
	// Absences (not late arrivals) by SMS too, where the school has it on.
	for _, r := range raw {
		if r.Status == domain.AttAbsent && before[r.StudentID] != r.Status {
			if st, ok := s.db(c).StudentByID(r.StudentID); ok {
				s.textFamily(c, st.ID, smsAbsence, schoolLabel(s.db(c))+": "+st.FullName()+
					" was marked absent on "+date+". Please contact the school if this is unexpected.")
			}
		}
	}
	s.audit(c, "attendance.save", classID+"/"+date, "Saved "+itoa(len(raw))+" attendance records", "")
	sendJSON(c, raw)
}

// studentAttendanceHistory returns recent records for a student.
func (s *Server) studentAttendanceHistory(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	var out []domain.AttendanceRecord
	for _, r := range s.db(c).Attendance() {
		if r.StudentID == st.ID {
			out = append(out, r)
		}
	}
	sendJSON(c, out)
}

// studentAttendanceSummary returns present/late/absent/excused totals +
// attendance percentage, mirroring AttendanceRepository.summaryForStudent.
func (s *Server) studentAttendanceSummary(c *gin.Context) {
	st, ok := s.db(c).StudentByID(c.Param("studentId"))
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if !s.canViewStudent(currentUser(c), st) {
		fail(c, http.StatusForbidden, "You may only view your own records")
		return
	}
	counts := map[string]int{}
	var total int
	for _, r := range s.db(c).Attendance() {
		if r.StudentID == st.ID {
			counts[r.Status]++
			total++
		}
	}
	pct := 0.0
	if total > 0 {
		pct = 100 * float64(counts[domain.AttPresent]+counts[domain.AttLate]) / float64(total)
	}
	sendJSON(c, domain.AttendanceSummary{
		StudentID: st.ID, Present: counts[domain.AttPresent], Late: counts[domain.AttLate],
		Absent: counts[domain.AttAbsent], Excused: counts[domain.AttExcused],
		TotalDays: total, Percentage: pct,
	})
}

// checkIn records an arrival (student-initiated for themselves, or staff for
// any student).
func (s *Server) checkIn(c *gin.Context) {
	var body struct {
		StudentID string `json:"studentId"`
		ClassID   string `json:"classId"`
		Time      string `json:"time"`
	}
	if !bind(c, &body) {
		return
	}
	u := currentUser(c)
	if !u.IsSchoolStaff() && stringToStudentID(u.ID) != body.StudentID {
		fail(c, http.StatusForbidden, "You may only check in yourself")
		return
	}
	st, ok := s.db(c).StudentByID(body.StudentID)
	if !ok {
		fail(c, http.StatusNotFound, "Student not found")
		return
	}
	if body.ClassID == "" {
		body.ClassID = st.ClassID
	}
	checkInTime := firstNonEmpty(body.Time, time.Now().Format("15:04"))
	date := today()
	rec := domain.AttendanceRecord{
		ID: "ATT" + date + "-" + st.ID, StudentID: st.ID, ClassID: body.ClassID, Date: date,
		Status: domain.AttPresent, CheckIn: checkInTime,
	}
	if writeFailed(c, s.db(c).SaveDay(body.ClassID, date, mergeDay(s.db(c).AttendanceForClassDate(body.ClassID, date), rec))) {
		return
	}
	s.audit(c, "attendance.checkin", st.ID, "Check-in recorded for "+st.FullName()+" at "+checkInTime, "")
	sendJSON(c, rec)
}

// attendanceCorrection fixes a previously recorded status, logging the reason
// to the audit trail (doc §49).
func (s *Server) attendanceCorrection(c *gin.Context) {
	var body struct {
		PlanDate   string   `json:"planDate"`
		StudentIDs []string `json:"studentIds"`
		OldStatus  string   `json:"oldStatus"`
		Status     string   `json:"status"`
		Reason     string   `json:"reason"`
	}
	if !bind(c, &body) {
		return
	}
	changed := []domain.AttendanceRecord{}
	for _, r := range s.db(c).Attendance() {
		if r.Date == body.PlanDate && contains(body.StudentIDs, r.StudentID) {
			if r.OldStatus == "" {
				r.OldStatus = r.Status
			}
			r.Status = body.Status
			changed = append(changed, r)
		}
	}
	if len(changed) == 0 {
		fail(c, http.StatusNotFound, "No matching attendance records")
		return
	}
	for _, r := range changed {
		r.Reason = body.Reason
		if writeFailed(c, s.db(c).SaveDay(r.ClassID, r.Date, mergeDay(s.db(c).AttendanceForClassDate(r.ClassID, r.Date), r))) {
			return
		}
	}
	s.audit(c, "attendance.correction", body.PlanDate, "Corrected "+itoa(len(changed))+" records to "+body.Status, body.Reason)
	sendJSON(c, changed)
}

func mergeDay(day []domain.AttendanceRecord, rec domain.AttendanceRecord) []domain.AttendanceRecord {
	out := make([]domain.AttendanceRecord, 0, len(day))
	replaced := false
	for _, r := range day {
		if r.ID == rec.ID {
			out = append(out, rec)
			replaced = true
		} else {
			out = append(out, r)
		}
	}
	if !replaced {
		out = append(out, rec)
	}
	return out
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func itoa(n int) string { return strconv.Itoa(n) }
