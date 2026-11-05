package httpapi

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/domain"
)

// Outbound webhooks let a school wire SOLVANTA into other systems: it POSTs a
// signed JSON event to each subscribed URL when something happens (a student is
// registered, a payment recorded, a gate event logged). Subscriptions are
// school-scoped and managed only by school leaders; the signing secret is shown
// once at creation and never returned again.
//
// Subscriptions are stored under the "webhooks" record kind, which is
// deliberately NOT exposed through the generic /records endpoint (so the secret
// cannot leak) — only the handlers here read or write it.

const webhookKind = "webhooks"

// webhookHTTP is the shared client for deliveries (short timeout, best-effort).
var webhookHTTP = &http.Client{Timeout: 10 * time.Second}

type webhookSub struct {
	ID     string   `json:"id"`
	URL    string   `json:"url"`
	Events []string `json:"events"` // event names, or ["*"] for all
	Secret string   `json:"secret"`
	Active bool     `json:"active"`
}

func (s *Server) loadWebhooks(c *gin.Context) []webhookSub {
	var out []webhookSub
	for _, r := range s.db(c).Records(webhookKind) {
		var w webhookSub
		if json.Unmarshal(r.Data, &w) == nil {
			w.ID = r.ID
			out = append(out, w)
		}
	}
	return out
}

// listWebhooks returns the subscriptions without their secrets.
func (s *Server) listWebhooks(c *gin.Context) {
	subs := s.loadWebhooks(c)
	out := make([]gin.H, 0, len(subs))
	for _, w := range subs {
		out = append(out, gin.H{"id": w.ID, "url": w.URL, "events": w.Events, "active": w.Active})
	}
	sendJSON(c, out)
}

// createWebhook registers a subscription and returns its signing secret once.
func (s *Server) createWebhook(c *gin.Context) {
	var body struct {
		URL    string   `json:"url"`
		Events []string `json:"events"`
	}
	if !bind(c, &body) {
		return
	}
	body.URL = strings.TrimSpace(body.URL)
	if !strings.HasPrefix(body.URL, "https://") && !strings.HasPrefix(body.URL, "http://") {
		fail(c, http.StatusBadRequest, "url must be http(s)")
		return
	}
	if len(body.Events) == 0 {
		body.Events = []string{"*"}
	}
	w := webhookSub{
		ID:     newID("WH"),
		URL:    body.URL,
		Events: body.Events,
		Secret: randomHex(24),
		Active: true,
	}
	data, _ := json.Marshal(w)
	if writeFailed(c, s.db(c).SaveRecord(domain.Record{Kind: webhookKind, ID: w.ID, UpdatedAt: now(), Data: data})) {
		return
	}
	s.audit(c, "webhook.create", w.ID, "Webhook to "+w.URL, "")
	// The secret is returned exactly once, here.
	sendCreated(c, gin.H{"id": w.ID, "url": w.URL, "events": w.Events, "secret": w.Secret})
}

func (s *Server) deleteWebhook(c *gin.Context) {
	id := c.Param("id")
	if _, ok := s.db(c).RecordByID(webhookKind, id); !ok {
		fail(c, http.StatusNotFound, "Webhook not found")
		return
	}
	if writeFailed(c, s.db(c).DeleteRecord(webhookKind, id)) {
		return
	}
	s.audit(c, "webhook.delete", id, "Removed webhook", "")
	sendJSON(c, gin.H{"deleted": id})
}

// fireEvent delivers an event to every active subscription that wants it. It is
// best-effort and asynchronous: a slow or failing receiver never affects the
// request that triggered it. Each delivery is signed with the subscription's
// secret (HMAC-SHA256 of the body) in the X-Solvanta-Signature header.
func (s *Server) fireEvent(c *gin.Context, event string, data any) {
	subs := s.loadWebhooks(c)
	if len(subs) == 0 {
		return
	}
	body, err := json.Marshal(gin.H{"event": event, "data": data, "at": now()})
	if err != nil {
		return
	}
	for _, w := range subs {
		if !w.Active || !webhookWants(w.Events, event) {
			continue
		}
		go deliverWebhook(w, event, body)
	}
}

func webhookWants(events []string, event string) bool {
	for _, e := range events {
		if e == "*" || e == event {
			return true
		}
	}
	return false
}

func deliverWebhook(w webhookSub, event string, body []byte) {
	mac := hmac.New(sha256.New, []byte(w.Secret))
	mac.Write(body)
	sig := "sha256=" + hex.EncodeToString(mac.Sum(nil))
	// A few attempts with linear backoff; drop silently after that.
	for attempt := 0; attempt < 3; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.URL, bytes.NewReader(body))
		if err != nil {
			cancel()
			return
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Solvanta-Event", event)
		req.Header.Set("X-Solvanta-Signature", sig)
		resp, err := webhookHTTP.Do(req)
		cancel()
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode < 300 {
				return
			}
		}
		time.Sleep(time.Duration(attempt+1) * 500 * time.Millisecond)
	}
}
