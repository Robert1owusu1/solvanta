// Package email sends transactional email (password resets, and future
// notices). Like the sms package, the provider is chosen once at startup from
// the environment; with nothing configured it is the log provider, which sends
// nothing and only records what would have gone out — so a deployment without
// an SMTP account keeps working and costs nothing.
//
//	SMTP_HOST=smtp.example.com SMTP_PORT=587 SMTP_USER=… SMTP_PASS=… EMAIL_FROM="SOLVANTA <no-reply@example.com>"
package email

import (
	"context"
	"fmt"
	"net/smtp"
	"os"
	"strings"
)

// Sender delivers one email.
type Sender interface {
	// Name is the provider, e.g. "smtp", or "log" when nothing is sent.
	Name() string
	// Send delivers a plain-text email to one address.
	Send(ctx context.Context, to, subject, body string) error
}

// FromEnv picks the SMTP provider when SMTP_HOST is set, else the log provider.
func FromEnv() Sender {
	host := os.Getenv("SMTP_HOST")
	if host == "" {
		return Log{}
	}
	return &SMTP{
		Host: host,
		Port: firstNonEmpty(os.Getenv("SMTP_PORT"), "587"),
		User: os.Getenv("SMTP_USER"),
		Pass: os.Getenv("SMTP_PASS"),
		From: firstNonEmpty(os.Getenv("EMAIL_FROM"), "SOLVANTA <no-reply@solvanta.app>"),
	}
}

// Log sends nothing; the caller records what would have gone out.
type Log struct{}

func (Log) Name() string                                       { return "log" }
func (Log) Send(context.Context, string, string, string) error { return nil }

// SMTP sends through a standard SMTP server with STARTTLS/PLAIN auth.
type SMTP struct {
	Host, Port, User, Pass, From string
}

func (s *SMTP) Name() string { return "smtp" }

func (s *SMTP) Send(_ context.Context, to, subject, body string) error {
	addr := s.Host + ":" + s.Port
	var auth smtp.Auth
	if s.User != "" {
		auth = smtp.PlainAuth("", s.User, s.Pass, s.Host)
	}
	msg := "From: " + s.From + "\r\n" +
		"To: " + to + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/plain; charset=UTF-8\r\n\r\n" +
		body + "\r\n"
	if err := smtp.SendMail(addr, auth, senderAddress(s.From), []string{to}, []byte(msg)); err != nil {
		return fmt.Errorf("email: %w", err)
	}
	return nil
}

// senderAddress extracts the bare address from a "Name <addr>" From header.
func senderAddress(from string) string {
	if i := strings.LastIndex(from, "<"); i >= 0 {
		if j := strings.Index(from[i:], ">"); j >= 0 {
			return from[i+1 : i+j]
		}
	}
	return from
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
