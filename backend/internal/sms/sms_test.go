package sms

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGhanaNumber(t *testing.T) {
	for in, want := range map[string]string{
		"024 123 4567":      "233241234567",
		"+233 24 123 4567":  "233241234567",
		"233241234567":      "233241234567",
		"0241234567":        "233241234567",
		"241234567":         "233241234567",
		"+44 20 7946 0958":  "",
		"12345":             "",
		"":                  "",
		"+233 024 123 4567": "",
	} {
		if got := GhanaNumber(in); got != want {
			t.Errorf("GhanaNumber(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestArkeselRequest(t *testing.T) {
	var got map[string]any
	var key string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key = r.Header.Get("api-key")
		_ = json.NewDecoder(r.Body).Decode(&got)
		if r.URL.Path != "/api/v2/sms/send" || r.Method != http.MethodPost {
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	a := &Arkesel{APIKey: "k", SenderID: "School", BaseURL: srv.URL}
	if err := a.Send(context.Background(), "", "233241234567", "Hello"); err != nil {
		t.Fatal(err)
	}
	if key != "k" || got["sender"] != "School" || got["message"] != "Hello" {
		t.Fatalf("request: key=%q body=%v", key, got)
	}
}

func TestHubtelRequestAndFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("to") != "233241234567" || q.Get("from") != "School" || q.Get("content") != "Hi" {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte("bad request"))
		}
	}))
	defer srv.Close()
	h := &Hubtel{ClientID: "id", ClientSecret: "s", SenderID: "School", BaseURL: srv.URL}
	if err := h.Send(context.Background(), "", "233241234567", "Hi"); err != nil {
		t.Fatal(err)
	}
	if err := h.Send(context.Background(), "School", "233241234567", "Other"); err == nil {
		t.Fatal("a 400 from the gateway must be an error")
	}
}

func TestFromEnvFallsBackToLog(t *testing.T) {
	t.Setenv("SMS_PROVIDER", "arkesel")
	t.Setenv("ARKESEL_API_KEY", "")
	if FromEnv().Name() != "log" {
		t.Fatal("arkesel without a key must not be used")
	}
	t.Setenv("ARKESEL_API_KEY", "k")
	if FromEnv().Name() != "arkesel" {
		t.Fatal("arkesel with a key")
	}
}
