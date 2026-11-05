package httpapi

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	"solvanta/backend/internal/push"
)

type capturePush struct {
	mu   sync.Mutex
	msgs []push.Message
}

func (c *capturePush) Name() string { return "test" }
func (c *capturePush) Send(_ context.Context, m push.Message) error {
	c.mu.Lock()
	c.msgs = append(c.msgs, m)
	c.mu.Unlock()
	return nil
}
func (c *capturePush) last() (push.Message, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.msgs) == 0 {
		return push.Message{}, false
	}
	return c.msgs[len(c.msgs)-1], true
}

func TestPushRegisterAndFanOut(t *testing.T) {
	cap := &capturePush{}
	r, _ := newTestServerWithStore(t, Config{Push: cap})

	// The parent of STU-001 registers a device.
	parent := bearer(login(t, r, "ama.owusu@school.gh", "parent123"))
	if rec := do(r, "POST", "/api/push/register", `{"token":"DEV-TOK-1","platform":"android"}`, parent); rec.Code != http.StatusOK {
		t.Fatalf("register: %d %s", rec.Code, rec.Body.String())
	}

	// A gate departure for their child notifies them → remote push fans out.
	teacher := bearer(login(t, r, "efua.mensah@school.gh", "teacher123"))
	if rec := do(r, "POST", "/api/gate/events",
		`{"studentId":"STU-001","type":"departure","time":"15:30","date":"2026-09-30"}`, teacher); rec.Code != http.StatusCreated {
		t.Fatalf("gate event: %d %s", rec.Code, rec.Body.String())
	}

	// The push send is async; wait briefly for it.
	var got push.Message
	for i := 0; i < 40; i++ {
		if m, ok := cap.last(); ok {
			got = m
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	if len(got.Tokens) == 0 {
		t.Fatal("no push was sent to the registered device")
	}
	if got.Tokens[0] != "DEV-TOK-1" {
		t.Errorf("pushed to %v, want the registered token", got.Tokens)
	}
	if got.Title == "" {
		t.Error("push had no title")
	}
}
