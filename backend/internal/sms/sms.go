// Package sms sends text messages to parents through a Ghanaian SMS gateway.
//
// The provider is chosen once at startup from the environment (FromEnv):
//
//	SMS_PROVIDER=arkesel  ARKESEL_API_KEY=…            SMS_SENDER_ID=MySchool
//	SMS_PROVIDER=hubtel   HUBTEL_CLIENT_ID=… HUBTEL_CLIENT_SECRET=… SMS_SENDER_ID=MySchool
//
// Anything else — including no configuration — is the log provider, which
// sends nothing and only records what would have gone out, so a deployment
// without a paid account keeps working and costs nothing.
//
// The gateway request shapes follow each provider's public HTTP API; check
// them against the provider's current documentation before going live.
package sms

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Sender delivers one message to one phone number.
type Sender interface {
	// Name is the provider, e.g. "arkesel", or "log" when nothing is sent.
	Name() string
	// Send delivers text to a number in international form (233XXXXXXXXX)
	// from sender ID from (the provider's default when empty).
	Send(ctx context.Context, from, to, text string) error
}

// FromEnv picks the provider configured in the environment.
func FromEnv() Sender {
	sender := firstNonEmpty(os.Getenv("SMS_SENDER_ID"), "SOLVANTA")
	client := &http.Client{Timeout: 15 * time.Second}
	switch strings.ToLower(os.Getenv("SMS_PROVIDER")) {
	case "arkesel":
		if key := os.Getenv("ARKESEL_API_KEY"); key != "" {
			return &Arkesel{APIKey: key, SenderID: sender, Client: client}
		}
	case "hubtel":
		id, secret := os.Getenv("HUBTEL_CLIENT_ID"), os.Getenv("HUBTEL_CLIENT_SECRET")
		if id != "" && secret != "" {
			return &Hubtel{ClientID: id, ClientSecret: secret, SenderID: sender, Client: client}
		}
	}
	return Log{}
}

// Log sends nothing: messages are only recorded by the caller.
type Log struct{}

func (Log) Name() string                                       { return "log" }
func (Log) Send(context.Context, string, string, string) error { return nil }

// Arkesel sends through Arkesel's v2 SMS API.
type Arkesel struct {
	APIKey, SenderID string
	BaseURL          string // tests; https://sms.arkesel.com by default
	Client           *http.Client
}

func (a *Arkesel) Name() string { return "arkesel" }

func (a *Arkesel) Send(ctx context.Context, from, to, text string) error {
	body, _ := json.Marshal(map[string]any{
		"sender": firstNonEmpty(from, a.SenderID), "message": text, "recipients": []string{to},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		firstNonEmpty(a.BaseURL, "https://sms.arkesel.com")+"/api/v2/sms/send", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("api-key", a.APIKey)
	req.Header.Set("Content-Type", "application/json")
	return do(a.Client, req)
}

// Hubtel sends through Hubtel's SMS API.
type Hubtel struct {
	ClientID, ClientSecret, SenderID string
	BaseURL                          string // tests; https://smsc.hubtel.com by default
	Client                           *http.Client
}

func (h *Hubtel) Name() string { return "hubtel" }

func (h *Hubtel) Send(ctx context.Context, from, to, text string) error {
	q := url.Values{
		"clientid": {h.ClientID}, "clientsecret": {h.ClientSecret},
		"from": {firstNonEmpty(from, h.SenderID)}, "to": {to}, "content": {text},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		firstNonEmpty(h.BaseURL, "https://smsc.hubtel.com")+"/v1/messages/send?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	return do(h.Client, req)
}

func do(c *http.Client, req *http.Request) error {
	if c == nil {
		c = http.DefaultClient
	}
	res, err := c.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(res.Body, 300))
		return fmt.Errorf("gateway answered %d: %s", res.StatusCode, strings.TrimSpace(string(msg)))
	}
	return nil
}

// GhanaNumber turns a phone number as typed in Ghana (024 123 4567,
// +233 24 123 4567, 233241234567) into 233XXXXXXXXX, or "" when it isn't a
// Ghanaian mobile number.
func GhanaNumber(phone string) string {
	d := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, phone)
	switch {
	case len(d) == 10 && d[0] == '0':
		d = "233" + d[1:]
	case len(d) == 9:
		d = "233" + d
	}
	if len(d) != 12 || !strings.HasPrefix(d, "233") || d[3] == '0' {
		return ""
	}
	return d
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
