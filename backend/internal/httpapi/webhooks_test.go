package httpapi

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestWebhookDeliversSignedEvent(t *testing.T) {
	type delivery struct {
		body  string
		event string
		sig   string
	}
	got := make(chan delivery, 1)
	receiver := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		select {
		case got <- delivery{string(b), r.Header.Get("X-Solvanta-Event"), r.Header.Get("X-Solvanta-Signature")}:
		default:
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer receiver.Close()

	r, _ := newTestServerWithStore(t, Config{})
	admin := bearer(login(t, r, "admin@solvanta.app", "admin123"))

	// Register a webhook for student.created and capture its secret.
	rec := do(r, "POST", "/api/webhooks",
		`{"url":"`+receiver.URL+`","events":["student.created"]}`, admin)
	if rec.Code != http.StatusCreated {
		t.Fatalf("register webhook: %d %s", rec.Code, rec.Body.String())
	}
	var created struct {
		Secret string `json:"secret"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if created.Secret == "" {
		t.Fatal("no secret returned")
	}

	// listing must not leak the secret
	list := do(r, "GET", "/api/webhooks", "", admin)
	if strings.Contains(list.Body.String(), created.Secret) {
		t.Error("listing leaked the webhook secret")
	}

	// Trigger the event.
	do(r, "POST", "/api/students",
		`{"firstName":"Esi","lastName":"Boateng","gender":"F","classId":"JHS2A"}`, admin)

	select {
	case d := <-got:
		if d.event != "student.created" {
			t.Errorf("event header = %q, want student.created", d.event)
		}
		if !strings.Contains(d.body, "student.created") || !strings.Contains(d.body, "Esi") {
			t.Errorf("payload missing event/data: %s", d.body)
		}
		mac := hmac.New(sha256.New, []byte(created.Secret))
		mac.Write([]byte(d.body))
		want := "sha256=" + hex.EncodeToString(mac.Sum(nil))
		if d.sig != want {
			t.Errorf("signature = %q, want %q", d.sig, want)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("webhook was not delivered")
	}
}
