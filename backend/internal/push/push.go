// Package push delivers remote notifications to devices. Like the sms and
// email packages, the provider is chosen once at startup from the environment;
// with nothing configured it is the log provider, which sends nothing — so the
// app keeps working and the notification still lands in the in-app feed.
//
//	FCM_SERVER_KEY=…   send through Firebase Cloud Messaging (legacy HTTP API)
//
// The device registers its token via POST /api/push/register; every in-app
// notification then also fans out to that user's registered devices.
package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

// Message is one notification to one or more device tokens.
type Message struct {
	Tokens []string
	Title  string
	Body   string
	Data   map[string]string
}

// Sender delivers a push message.
type Sender interface {
	// Name is the provider, e.g. "fcm", or "log" when nothing is sent.
	Name() string
	Send(ctx context.Context, m Message) error
}

// FromEnv picks FCM when FCM_SERVER_KEY is set, else the log provider.
func FromEnv() Sender {
	if key := os.Getenv("FCM_SERVER_KEY"); key != "" {
		return &FCM{Key: key, Client: &http.Client{Timeout: 15 * time.Second}}
	}
	return Log{}
}

// Log sends nothing; the in-app feed is the only delivery.
type Log struct{}

func (Log) Name() string                        { return "log" }
func (Log) Send(context.Context, Message) error { return nil }

// FCM sends through Firebase Cloud Messaging's legacy HTTP endpoint. Swap for
// the HTTP v1 API (OAuth service account) when you move off the legacy key.
type FCM struct {
	Key    string
	Client *http.Client
}

func (f *FCM) Name() string { return "fcm" }

func (f *FCM) Send(ctx context.Context, m Message) error {
	if len(m.Tokens) == 0 {
		return nil
	}
	payload, _ := json.Marshal(map[string]any{
		"registration_ids": m.Tokens,
		"notification":     map[string]string{"title": m.Title, "body": m.Body},
		"data":             m.Data,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://fcm.googleapis.com/fcm/send", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "key="+f.Key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := f.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("fcm: status %d", resp.StatusCode)
	}
	return nil
}
