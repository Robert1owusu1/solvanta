package security

import (
	"strings"
	"testing"
)

func TestHashAndVerify(t *testing.T) {
	h, err := HashPassword("DemoPass1")
	if err != nil {
		t.Fatal(err)
	}
	if h == "DemoPass1" {
		t.Fatal("password stored in plaintext")
	}
	if !VerifyPassword(h, "DemoPass1") {
		t.Fatal("correct password rejected")
	}
	if VerifyPassword(h, "DemoPass2") {
		t.Fatal("wrong password accepted")
	}
	if VerifyPassword("not-a-hash", "DemoPass1") {
		t.Fatal("malformed hash accepted")
	}
}

func TestPasswordPolicy(t *testing.T) {
	weak := []string{"short", "alllowercase1", "ALLCAPS1", "NoDigitsHere", "noupperlower1"}
	for _, pw := range weak {
		if err := ValidatePasswordPolicy(pw); err == nil {
			t.Fatalf("%q should fail the policy", pw)
		}
	}
	strong := []string{"ValidPass1", "Str0ng-Passw0rd!", "abcDEF123"}
	for _, pw := range strong {
		if err := ValidatePasswordPolicy(pw); err != nil {
			t.Fatalf("%q should pass the policy: %v", pw, err)
		}
	}
}

func TestRandomFunctions(t *testing.T) {
	a, err := RandomHex(16)
	if err != nil {
		t.Fatal(err)
	}
	b, err := RandomHex(16)
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != 32 || a == b {
		t.Fatal("RandomHex must be unique and correctly sized")
	}
	tok, err := RandomToken(32)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.ContainsRune(tok, '=') {
		// raw-url encoding must be URL-safe (no padding) for header use
		if strings.ContainsAny(tok, "+/=") {
			t.Fatal("token should be URL-safe base64")
		}
	}
	if HashToken(tok) == tok || len(HashToken(tok)) != 64 {
		t.Fatal("HashToken must be a SHA-256 hex digest")
	}
}

func TestConstantTimeEqual(t *testing.T) {
	if !ConstantTimeEqual("abc", "abc") {
		t.Fatal("equal strings rejected")
	}
	if ConstantTimeEqual("abc", "abd") {
		t.Fatal("different strings accepted")
	}
	if ConstantTimeEqual("ab", "abc") {
		t.Fatal("length mismatch accepted")
	}
}
