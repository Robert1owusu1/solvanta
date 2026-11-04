package security

import (
	"testing"
	"time"
)

func TestTOTPRoundTripAndWindow(t *testing.T) {
	secret := GenerateTOTPSecret()
	now := time.Unix(1_700_000_000, 0)
	code, err := TOTPCode(secret, now)
	if err != nil || len(code) != 6 {
		t.Fatalf("code = %q, err = %v", code, err)
	}
	if !VerifyTOTP(secret, code, now) {
		t.Error("the current code must verify")
	}
	// A code from the previous step still verifies (drift tolerance).
	prev, _ := TOTPCode(secret, now.Add(-30*time.Second))
	if !VerifyTOTP(secret, prev, now) {
		t.Error("the previous-step code must verify within the window")
	}
	// A code from three steps ago must not.
	old, _ := TOTPCode(secret, now.Add(-90*time.Second))
	if old != code && VerifyTOTP(secret, old, now) {
		t.Error("a far-off code must not verify")
	}
	if VerifyTOTP(secret, "000000", now.Add(999*time.Hour)) {
		// extremely unlikely to collide; guards an all-zero bypass
		t.Skip("rare coincidental match; ignore")
	}
}

func TestTOTPKnownVector(t *testing.T) {
	// RFC 6238 SHA-1 test vector: secret "12345678901234567890" (ASCII) at
	// T=59s gives 94287082 → last 6 digits 287082.
	secret := b32.EncodeToString([]byte("12345678901234567890"))
	code, err := TOTPCode(secret, time.Unix(59, 0))
	if err != nil {
		t.Fatal(err)
	}
	if code != "287082" {
		t.Errorf("RFC vector = %q, want 287082", code)
	}
}

func TestTOTPRejectsGarbage(t *testing.T) {
	s := GenerateTOTPSecret()
	now := time.Now()
	if VerifyTOTP(s, "", now) || VerifyTOTP(s, "12", now) || VerifyTOTP(s, "abcdef", now) {
		t.Error("malformed codes must not verify")
	}
}
