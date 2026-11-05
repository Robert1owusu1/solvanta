package security

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// TOTP (RFC 6238) for two-factor sign-in: 6 digits, 30-second steps, SHA-1 —
// the parameters every authenticator app (Google Authenticator, Authy, …)
// defaults to. No external dependency.

const (
	totpDigits = 6
	totpStep   = 30 * time.Second
)

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// GenerateTOTPSecret returns a fresh base32 secret (160 bits) for a new
// enrolment.
func GenerateTOTPSecret() string {
	buf := make([]byte, 20)
	if _, err := rand.Read(buf); err != nil {
		// RandomHex-style fallback is never expected; panic would take the
		// server down, so return a time-seeded secret instead.
		binary.BigEndian.PutUint64(buf, uint64(time.Now().UnixNano()))
	}
	return b32.EncodeToString(buf)
}

// TOTPCode is the 6-digit code for a secret at a moment in time.
func TOTPCode(secret string, t time.Time) (string, error) {
	key, err := b32.DecodeString(strings.ToUpper(strings.TrimSpace(secret)))
	if err != nil {
		return "", fmt.Errorf("totp: bad secret: %w", err)
	}
	counter := uint64(t.Unix()) / uint64(totpStep.Seconds())
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], counter)
	mac := hmac.New(sha1.New, key)
	mac.Write(msg[:])
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	bin := (uint32(sum[offset]&0x7f) << 24) |
		(uint32(sum[offset+1]) << 16) |
		(uint32(sum[offset+2]) << 8) |
		uint32(sum[offset+3])
	mod := uint32(1)
	for i := 0; i < totpDigits; i++ {
		mod *= 10
	}
	return fmt.Sprintf("%0*d", totpDigits, bin%mod), nil
}

// VerifyTOTP reports whether code is valid for the secret at time t, allowing
// the adjacent 30-second windows to tolerate clock drift. The comparison is
// constant-time per candidate.
func VerifyTOTP(secret, code string, t time.Time) bool {
	code = strings.TrimSpace(code)
	if len(code) != totpDigits {
		return false
	}
	for _, skew := range []time.Duration{0, -totpStep, totpStep} {
		want, err := TOTPCode(secret, t.Add(skew))
		if err != nil {
			return false
		}
		if hmac.Equal([]byte(want), []byte(code)) {
			return true
		}
	}
	return false
}

// TOTPURI builds the otpauth:// URI an authenticator app scans as a QR code.
func TOTPURI(issuer, account, secret string) string {
	label := url.PathEscape(issuer + ":" + account)
	q := url.Values{}
	q.Set("secret", secret)
	q.Set("issuer", issuer)
	q.Set("digits", fmt.Sprintf("%d", totpDigits))
	q.Set("period", "30")
	return "otpauth://totp/" + label + "?" + q.Encode()
}
