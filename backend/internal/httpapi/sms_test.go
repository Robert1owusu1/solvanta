package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
)

// fakeGateway records texts; numbers in failFor fail.
type fakeGateway struct {
	mu      sync.Mutex
	sent    []string
	from    []string
	failFor string
}

func (f *fakeGateway) Name() string { return "fake" }

func (f *fakeGateway) Send(_ context.Context, from, to, text string) error {
	if to == f.failFor {
		return errors.New("gateway down")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.from = append(f.from, from)
	f.sent = append(f.sent, to+": "+text)
	return nil
}

func (f *fakeGateway) texts() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.sent...)
}

const allOn = `{"enabled":true,"reportCards":true,"absences":true,"meetings":true,"feeReminders":true}`

func TestSMSIsOffUntilTheSchoolTurnsItOn(t *testing.T) {
	gw := &fakeGateway{}
	r := newTestServer(t, Config{SMS: gw, SMSInline: true})
	head := login(t, r, "head@school.gh", "head123")
	do(r, "PUT", reportPath, reportBody("approved", "Good.", "Good."), bearer(head))
	if len(gw.texts()) != 0 {
		t.Fatalf("texts sent with SMS off: %v", gw.texts())
	}
	if rec := do(r, "POST", "/api/sms/fee-reminders", "", bearer(head)); rec.Code != http.StatusConflict {
		t.Errorf("fee reminders while off: got %d, want 409", rec.Code)
	}
}

func TestSMSSettingsAndLogAreForLeaders(t *testing.T) {
	r := newTestServer(t, Config{SMS: &fakeGateway{}, SMSInline: true})
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	head := login(t, r, "head@school.gh", "head123")
	admin := login(t, r, "admin@solvanta.app", "admin123")
	if rec := do(r, "PUT", "/api/sms/settings", allOn, bearer(head)); rec.Code != http.StatusForbidden {
		t.Errorf("headteacher changing SMS settings: got %d, want 403", rec.Code)
	}
	if rec := do(r, "PUT", "/api/sms/settings", allOn, bearer(admin)); rec.Code != http.StatusOK {
		t.Fatalf("admin turning SMS on: %d", rec.Code)
	}
	for _, path := range []string{"/api/sms/settings", "/api/sms/log"} {
		if code := getJSON(t, r, teacher, path, nil); code != http.StatusForbidden {
			t.Errorf("teacher reading %s: got %d, want 403", path, code)
		}
		if code := getJSON(t, r, head, path, nil); code != http.StatusOK {
			t.Errorf("headteacher reading %s: got %d", path, code)
		}
	}
	// Not reachable through the generic records API either.
	if code := getJSON(t, r, admin, "/api/records/sms_log", nil); code != http.StatusNotFound {
		t.Errorf("sms log via /api/records: got %d, want 404", code)
	}
}

func TestSMSEventsTextTheFamily(t *testing.T) {
	gw := &fakeGateway{failFor: "233246600001"} // STU-005's guardian
	r := newTestServer(t, Config{SMS: gw, SMSInline: true})
	admin := login(t, r, "admin@solvanta.app", "admin123")
	head := login(t, r, "head@school.gh", "head123")
	teacher := login(t, r, "efua.mensah@school.gh", "teacher123")
	do(r, "PUT", "/api/sms/settings", allOn, bearer(admin))

	// Report card approved.
	do(r, "PUT", reportPath, reportBody("approved", "Good.", "Good."), bearer(head))
	// A meeting booked.
	do(r, "PUT", "/api/records/parent_meetings/MEET-1", meeting("scheduled", "2026-12-04 10:00"), bearer(teacher))
	// Absences: STU-001 (texts) and STU-005 (gateway fails).
	roll := `[{"id":"A1","studentId":"STU-001","classId":"JHS2A","date":"2026-10-12","status":"absent"},
	          {"id":"A5","studentId":"STU-005","classId":"JHS2A","date":"2026-10-12","status":"absent"}]`
	if rec := do(r, "PUT", "/api/attendance/class/JHS2A/date/2026-10-12", roll, bearer(teacher)); rec.Code != http.StatusOK {
		t.Fatalf("save roll: %d %s", rec.Code, rec.Body.String())
	}
	// Re-saving the same roll does not text again.
	do(r, "PUT", "/api/attendance/class/JHS2A/date/2026-10-12", roll, bearer(teacher))

	all := strings.Join(gw.texts(), "\n")
	for _, want := range []string{"report card is ready", "please meet us on 2026-12-04 10:00", "was marked absent on 2026-10-12"} {
		if !strings.Contains(all, want) {
			t.Errorf("no text containing %q in:\n%s", want, all)
		}
	}
	// Kojo's family (two numbers) is texted once each — not again when the
	// same roll is saved twice; Yaw's only number fails at the gateway.
	if got := strings.Count(all, "Kojo Owusu was marked absent"); got != 2 {
		t.Errorf("Kojo's absence texts: got %d, want 2:\n%s", got, all)
	}
	if strings.Contains(all, "Yaw Darko was marked absent") {
		t.Errorf("a failed text was reported as sent:\n%s", all)
	}

	var logged []smsLogEntry
	getJSON(t, r, head, "/api/sms/log", &logged)
	failed := 0
	for _, e := range logged {
		if e.Status == "failed" {
			failed++
			if e.Error == "" {
				t.Error("a failed text must say why")
			}
		}
	}
	if failed != 1 || len(logged) < 4 {
		t.Fatalf("log: %+v", logged)
	}
}

func TestFeeRemindersTextFamiliesWhoOwe(t *testing.T) {
	gw := &fakeGateway{}
	r := newTestServer(t, Config{SMS: gw, SMSInline: true})
	admin := login(t, r, "admin@solvanta.app", "admin123")
	do(r, "PUT", "/api/sms/settings", allOn, bearer(admin))
	var res struct{ Families, Texts int }
	rec := do(r, "POST", "/api/sms/fee-reminders", "", bearer(admin))
	if rec.Code != http.StatusOK {
		t.Fatalf("fee reminders: %d %s", rec.Code, rec.Body.String())
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &res)
	if res.Texts != len(gw.texts()) {
		t.Fatalf("reported %d texts, sent %d", res.Texts, len(gw.texts()))
	}
	for _, text := range gw.texts() {
		if !strings.Contains(text, "GHS ") || strings.Contains(text, "₵") {
			t.Errorf("fee text should use GHS (plain SMS alphabet): %s", text)
		}
	}
}

func TestSMSSenderNameAndUsagePerSchool(t *testing.T) {
	gw := &fakeGateway{}
	r := newTestServer(t, Config{SMS: gw, SMSInline: true})
	admin := login(t, r, "admin@solvanta.app", "admin123")
	head := login(t, r, "head@school.gh", "head123")
	bad := strings.Replace(allOn, `{`, `{"senderId":"Way Too Long Name",`, 1)
	if rec := do(r, "PUT", "/api/sms/settings", bad, bearer(admin)); rec.Code != http.StatusBadRequest {
		t.Errorf("12-character sender name: got %d, want 400", rec.Code)
	}
	named := strings.Replace(allOn, `{`, `{"senderId":"AccraJHS",`, 1)
	if rec := do(r, "PUT", "/api/sms/settings", named, bearer(admin)); rec.Code != http.StatusOK {
		t.Fatalf("set sender name: %d", rec.Code)
	}
	do(r, "PUT", reportPath, reportBody("approved", "Good.", "Good."), bearer(head))
	if len(gw.from) == 0 || gw.from[0] != "AccraJHS" {
		t.Fatalf("texts sent from %v, want AccraJHS", gw.from)
	}
	var res struct {
		Usage struct{ Sent int } `json:"usage"`
	}
	getJSON(t, r, head, "/api/sms/settings", &res)
	if res.Usage.Sent != len(gw.texts()) {
		t.Fatalf("usage says %d sent, gateway got %d", res.Usage.Sent, len(gw.texts()))
	}
}
