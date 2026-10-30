package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
	"solvanta/backend/internal/sms"
	"solvanta/backend/internal/store"
)

// Each school decides which events text its parents. Everything is off
// until its admin turns it on: texts cost the school money.
type smsSettings struct {
	// SenderID is the name parents see (registered with the provider);
	// empty uses the platform's.
	SenderID     string `json:"senderId"`
	Enabled      bool   `json:"enabled"`
	ReportCards  bool   `json:"reportCards"`
	Absences     bool   `json:"absences"`
	Meetings     bool   `json:"meetings"`
	FeeReminders bool   `json:"feeReminders"`
}

// Kept as internal records: not exposed through /api/records, so only the
// endpoints below can read or write them.
const (
	recordSMSSettings = "sms_settings"
	recordSMSLog      = "sms_log"
	smsSettingsID     = "sms"
)

// What a text is about; each matches a setting.
const (
	smsReportCard  = "reportCard"
	smsAbsence     = "absence"
	smsMeeting     = "meeting"
	smsFeeReminder = "feeReminder"
)

type smsJob struct {
	st        store.Store
	from      string
	studentID string
	purpose   string
	to        string
	text      string
}

// smsLogEntry is one attempted text, for the school's log.
type smsLogEntry struct {
	ID        string `json:"id"`
	StudentID string `json:"studentId"`
	Purpose   string `json:"purpose"`
	To        string `json:"to"`
	Text      string `json:"text"`
	Status    string `json:"status"` // sent | failed | logged (no provider)
	Provider  string `json:"provider"`
	Error     string `json:"error,omitempty"`
	At        string `json:"at"`
}

func settingsOf(st store.Store) smsSettings {
	var cfg smsSettings
	if r, ok := st.RecordByID(recordSMSSettings, smsSettingsID); ok {
		_ = json.Unmarshal(r.Data, &cfg)
	}
	return cfg
}

func (cfg smsSettings) allows(purpose string) bool {
	if !cfg.Enabled {
		return false
	}
	switch purpose {
	case smsReportCard:
		return cfg.ReportCards
	case smsAbsence:
		return cfg.Absences
	case smsMeeting:
		return cfg.Meetings
	case smsFeeReminder:
		return cfg.FeeReminders
	}
	return false
}

// familyNumbers are the student's guardians' and linked parent's phones, as
// Ghanaian mobile numbers, without repeats.
func familyNumbers(st store.Store, student domain.Student) []string {
	seen := map[string]bool{}
	var out []string
	add := func(phone string) {
		if n := sms.GhanaNumber(phone); n != "" && !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	for _, g := range student.Guardians {
		add(g.Phone)
	}
	if student.ParentUserID != "" {
		if u, ok := st.UserByID(student.ParentUserID); ok {
			add(u.Phone)
		}
	}
	return out
}

// textFamily texts a student's family about purpose, if the school has
// turned that on. It returns how many texts were queued.
func (s *Server) textFamily(c *gin.Context, studentID, purpose, text string) int {
	st := s.db(c)
	if !settingsOf(st).allows(purpose) {
		return 0
	}
	student, ok := st.StudentByID(studentID)
	if !ok {
		return 0
	}
	n := 0
	from := settingsOf(st).SenderID
	for _, to := range familyNumbers(st, student) {
		s.dispatchSMS(smsJob{st: st, from: from, studentID: studentID, purpose: purpose, to: to, text: text})
		n++
	}
	return n
}

func (s *Server) dispatchSMS(j smsJob) {
	if s.smsJobs == nil {
		s.deliver(j)
		return
	}
	select {
	case s.smsJobs <- j:
	default:
		log.Printf("sms: queue full, dropping %s to %s", j.purpose, j.to)
		s.record(j, "failed", "queue full")
	}
}

func (s *Server) smsWorker() {
	for j := range s.smsJobs {
		s.deliver(j)
	}
}

func (s *Server) deliver(j smsJob) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if s.sms.Name() == "log" {
		s.record(j, "logged", "")
		return
	}
	if err := s.sms.Send(ctx, j.from, j.to, j.text); err != nil {
		s.record(j, "failed", err.Error())
		return
	}
	s.record(j, "sent", "")
}

func (s *Server) record(j smsJob, status, errText string) {
	e := smsLogEntry{
		ID: newID("SMS"), StudentID: j.studentID, Purpose: j.purpose, To: j.to,
		Text: j.text, Status: status, Provider: s.sms.Name(), Error: errText, At: now(),
	}
	data, _ := json.Marshal(e)
	if err := j.st.SaveRecord(domain.Record{
		Kind: recordSMSLog, ID: e.ID, StudentID: e.StudentID, UpdatedAt: e.At, Data: data,
	}); err != nil {
		log.Printf("sms: could not log %s: %v", e.ID, err)
	}
}

func (s *Server) smsSettingsGet(c *gin.Context) {
	sendJSON(c, gin.H{"settings": settingsOf(s.db(c)), "provider": s.sms.Name(), "usage": smsUsage(s.db(c))})
}

// senderIDPattern: Ghanaian networks accept 3–11 letters, digits or spaces.
var senderIDPattern = regexp.MustCompile(`^[A-Za-z0-9 ]{3,11}$`)

// smsUsage counts this month's texts by outcome — what the school is
// billed for.
func smsUsage(st store.Store) gin.H {
	month := time.Now().Format("2006-01")
	counts := map[string]int{"sent": 0, "failed": 0, "logged": 0}
	for _, r := range st.Records(recordSMSLog) {
		var e smsLogEntry
		if json.Unmarshal(r.Data, &e) == nil && strings.HasPrefix(e.At, month) {
			counts[e.Status]++
		}
	}
	return gin.H{"month": month, "sent": counts["sent"], "failed": counts["failed"], "logged": counts["logged"]}
}

func (s *Server) smsSettingsPut(c *gin.Context) {
	var body smsSettings
	if !bind(c, &body) {
		return
	}
	body.SenderID = strings.TrimSpace(body.SenderID)
	if body.SenderID != "" && !senderIDPattern.MatchString(body.SenderID) {
		fail(c, http.StatusBadRequest, "The sender name must be 3–11 letters, digits or spaces")
		return
	}
	data, _ := json.Marshal(body)
	if writeFailed(c, s.db(c).SaveRecord(domain.Record{
		Kind: recordSMSSettings, ID: smsSettingsID, UpdatedAt: now(), Data: data,
	})) {
		return
	}
	s.audit(c, "sms.settings", smsSettingsID, fmt.Sprintf("SMS settings: %+v", body), "")
	sendJSON(c, gin.H{"settings": body, "provider": s.sms.Name()})
}

// smsLog is the school's last 200 texts, newest first.
func (s *Server) smsLog(c *gin.Context) {
	var out []smsLogEntry
	for _, r := range s.db(c).Records(recordSMSLog) {
		var e smsLogEntry
		if json.Unmarshal(r.Data, &e) == nil {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At > out[j].At || (out[i].At == out[j].At && out[i].ID > out[j].ID) })
	if len(out) > 200 {
		out = out[:200]
	}
	sendJSON(c, out)
}

// smsFeeReminders texts every family with fees outstanding.
func (s *Server) smsFeeReminders(c *gin.Context) {
	st := s.db(c)
	if !settingsOf(st).allows(smsFeeReminder) {
		fail(c, http.StatusConflict, "Fee reminders by SMS are turned off for this school")
		return
	}
	owing := map[string]int{}
	for _, inv := range st.Invoices() {
		if bal := inv.Total() - inv.AmountPaid; bal > 0 {
			owing[inv.StudentID] += bal
		}
	}
	families, texts := 0, 0
	for id, amount := range owing {
		student, ok := st.StudentByID(id)
		if !ok {
			continue
		}
		// "GHS", not the cedi sign: it keeps the text in the plain SMS
		// alphabet (160 characters a part instead of 70).
		n := s.textFamily(c, id, smsFeeReminder, fmt.Sprintf(
			"%s: %s has GHS %d in school fees outstanding. Please pay at the school office. Thank you.",
			schoolLabel(st), student.FullName(), amount))
		if n > 0 {
			families++
			texts += n
		}
	}
	s.audit(c, "sms.fee_reminders", "", fmt.Sprintf("Fee reminders: %d texts to %d families", texts, families), "")
	sendJSON(c, gin.H{"families": families, "texts": texts})
}

// schoolLabel signs a text: the school's name, or SOLVANTA.
func schoolLabel(st store.Store) string {
	if n := st.School().Name; n != "" {
		return n
	}
	return "SOLVANTA"
}
