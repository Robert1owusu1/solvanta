// Package security provides the platform's credential and token primitives:
// bcrypt password hashing (doc §54 web dashboard adjoins the same stack),
// opaque session tokens and password policy. Nothing here depends on the rest
// of the backend, so it stays tiny and auditable.
package security

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"unicode"

	"golang.org/x/crypto/bcrypt"
)

// ErrWeakPassword is returned when a new password fails the policy checks.
var ErrWeakPassword = errors.New("password does not meet the policy")

// HashPassword returns a bcrypt hash of pw with the default cost.
func HashPassword(pw string) (string, error) {
	if pw == "" {
		return "", errors.New("empty password")
	}
	b, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// VerifyPassword compares pw against a bcrypt hash. It returns false for any
// malformed hash rather than leaking whether the hash itself was invalid.
func VerifyPassword(hash, pw string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(pw)) == nil
}

// ValidatePasswordPolicy checks the platform's minimum standard: 8+ chars
// with at least one lower-case, one upper-case and one digit.
func ValidatePasswordPolicy(pw string) error {
	if len(pw) < 8 {
		return fmt.Errorf("%w: at least 8 characters", ErrWeakPassword)
	}
	var hasLower, hasUpper, hasDigit bool
	for _, r := range pw {
		switch {
		case unicode.IsLower(r):
			hasLower = true
		case unicode.IsUpper(r):
			hasUpper = true
		case unicode.IsDigit(r):
			hasDigit = true
		}
	}
	if !hasLower || !hasUpper || !hasDigit {
		return fmt.Errorf("%w: needs lower-case, upper-case and a digit", ErrWeakPassword)
	}
	return nil
}

// RandomToken returns n cryptographically random bytes as raw URL-base64 —
// suitable for opaque refresh tokens (they are stored only as hashes).
func RandomToken(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// RandomHex returns n random bytes as hex (request ids, JTI).
func RandomHex(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// HashToken returns the SHA-256 hex digest of an opaque token. Refresh
// tokens are persisted only in this form so a database leak cannot be used to
// replay sessions.
func HashToken(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// ConstantTimeEqual compares two strings in constant time; used when hashes
// are already compared inside bcrypt, this guards any remaining comparisons.
func ConstantTimeEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}
