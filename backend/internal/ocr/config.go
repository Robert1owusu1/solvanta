package ocr

import "os"

// Config holds the credentials the real providers need.
//
// Every field comes from the environment and nothing else. Keys are never
// committed, never logged, never echoed in a response body, and never asked
// for in chat. An empty field means "not installed yet", which is the normal
// state of this deployment today — and it is not an error: it routes that
// content to MockProvider instead.
type Config struct {
	// MathpixAppID and MathpixAppKey authenticate Mathpix (MATHPIX_APP_ID,
	// MATHPIX_APP_KEY). Both are required before the math-notation route
	// leaves the mock; either one alone leaves it there.
	MathpixAppID  string
	MathpixAppKey string

	// VisionAPIKey authenticates Google Cloud Vision (GOOGLE_VISION_API_KEY).
	// Absent leaves the plain-text route on the mock.
	//
	// Only API-key authentication is implemented. Google's service-account
	// flow (workload identity, GOOGLE_APPLICATION_CREDENTIALS) is a
	// different auth path — an OAuth2 token exchange rather than a key on
	// the query string — and is deliberately not faked here; see
	// backend/README.md.
	VisionAPIKey string
}

// FromEnv reads credentials from the environment.
//
// Deliberately os.Getenv rather than a config file: the process already takes
// its other secrets from the environment, and keeping these here means a key
// never lands in the repository or in a checked-in .env.
func FromEnv() Config {
	return Config{
		MathpixAppID:  os.Getenv("MATHPIX_APP_ID"),
		MathpixAppKey: os.Getenv("MATHPIX_APP_KEY"),
		VisionAPIKey:  os.Getenv("GOOGLE_VISION_API_KEY"),
	}
}

// MathpixReady reports whether the math-notation route can leave the mock.
func (c Config) MathpixReady() bool {
	return c.MathpixAppID != "" && c.MathpixAppKey != ""
}

// VisionReady reports whether the plain-text route can leave the mock.
func (c Config) VisionReady() bool {
	return c.VisionAPIKey != ""
}
