// Package ocr turns a photographed page of student work into normalised text.
//
// Two real engines are supported and routed by content type: Mathpix for
// math-notation content (equations, fractions) and Google Cloud Vision for
// plain handwriting. Both normalise into the same Result, so nothing
// downstream — the question endpoint, the marking pipeline, the teacher
// confirmation step — ever needs to know which engine produced a page.
//
// Nothing in this package is required at boot. When the credentials for a
// route are absent, the router serves MockProvider instead: deterministic
// text, no network, no key. That is what lets this package and everything
// built on top of it be developed and tested with no API keys at all.
package ocr

import (
	"context"
	"errors"
	"net/http"
	"strings"
)

// Kind names a provider family.
type Kind string

const (
	// KindMathpix reads math notation (equations, fractions) into LaTeX.
	KindMathpix Kind = "mathpix"
	// KindVision reads plain handwriting into text.
	KindVision Kind = "google_vision"
	// KindMock is the no-key stand-in for either of the above.
	KindMock Kind = "mock"
)

// valid reports whether the router may be told to use k.
//
// An override naming anything else is a mistake. Quietly routing a student's
// answer to the wrong engine — or accepting nonsense as a provider name — is
// worse than refusing the override, so the router drops it instead.
func (k Kind) valid() bool {
	return k == KindMathpix || k == KindVision || k == KindMock
}

// CostTier records which rate tier a page fell into.
//
// Mathpix bills at a higher per-page rate above [MathpixHighRateLines] lines
// of recognised text. The tier is computed on every run — mock runs included —
// so the logging built on it is already exercised, and already proven, from
// before the first real key is installed rather than first being tried once
// money is at stake.
type CostTier string

const (
	// TierStandard is the base per-page rate.
	TierStandard CostTier = "standard"
	// TierHigh is the rate above the line threshold.
	TierHigh CostTier = "high"
)

// MathpixHighRateLines is the recognised line count above which Mathpix's
// higher per-page rate applies.
const MathpixHighRateLines = 12

// tierForLines maps a recognised line count onto a rate tier.
func tierForLines(lines int) CostTier {
	if lines > MathpixHighRateLines {
		return TierHigh
	}
	return TierStandard
}

// ErrNoImage reports that a real engine was handed an empty photo.
var ErrNoImage = errors.New("ocr: no image supplied")

// Doer is the slice of *http.Client that the real providers actually need.
//
// Both real engines take an injected Doer rather than building their own
// client, which is what lets their request and response handling be exercised
// against a stub in tests — they can be proven to build the right request and
// parse the right fields while no key exists and no packet leaves the machine.
type Doer interface {
	Do(*http.Request) (*http.Response, error)
}

// contentTypeFor returns the MIME type to label an image with, defaulting to
// JPEG when the caller did not know. Mathpix wants it embedded in the data
// URL, so an empty value must not turn into "data:;base64," — that fails at
// the far end with an unhelpful error instead of being guessed correctly here.
func contentTypeFor(in Input) string {
	ct := strings.TrimSpace(in.ContentType)
	if ct == "" {
		return "image/jpeg"
	}
	return ct
}

// Input is a single page to recognise.
type Input struct {
	// PageID identifies the page in logs and in the Result. Optional, and
	// deliberately carries nothing about the student.
	PageID string
	// Image is the raw photo bytes. MockProvider tolerates an empty image
	// (it has nothing to read anyway); the real providers require one and
	// return [ErrNoImage] otherwise.
	Image []byte
	// ContentType is the photo's MIME type, e.g. "image/jpeg".
	ContentType string
	// SubjectID drives the subject-level routing default.
	SubjectID string
}

// Result is the normalised OCR output that every provider produces.
//
// Downstream code reads Text (and Math, where the engine produced any) and
// never branches on Provider. The engine name is recorded for audit and cost
// reporting — not for deciding what an answer means.
type Result struct {
	// Text is the recognised plain text, line separated.
	Text string
	// Math holds structured math notation (LaTeX) when the engine produced
	// any. Empty for plain handwriting.
	Math string
	// Confidence is 0..1. Zero means the engine did not report a score,
	// which is NOT the same as reporting low confidence — the two are not
	// interchangeable and the confirmation step must not treat them as such.
	Confidence float64
	// Lines is the number of lines in Text: the input to the cost tier.
	Lines int
	// Provider is the engine that actually produced this result.
	Provider Kind
	// CostTier is the rate tier this page fell into.
	CostTier CostTier
	// DurationMS is how long the engine took.
	DurationMS int64
	// RequestID is the engine's own id for the call, when it returns one.
	// Useful for a support ticket; contains nothing about the student.
	RequestID string
	// Warnings are non-fatal notes (low confidence, unreadable region) for
	// the teacher confirmation step to surface. Never silently dropped.
	Warnings []string
}

// Provider recognises one page of student work.
type Provider interface {
	// Kind names the engine. MockProvider reports KindMock even while
	// standing in for a paid route, so startup logging can never imply a
	// real engine is live when it is not.
	Kind() Kind
	// Recognize converts one image into a normalised Result.
	Recognize(ctx context.Context, in Input) (*Result, error)
}

// countLines counts the lines of recognised text.
//
// Deliberately tolerant of trailing newlines: an engine that terminates every
// line would otherwise bill a 12-line page as 13 and push it over the rate
// threshold for no reason.
func countLines(s string) int {
	trimmed := strings.TrimRight(s, "\r\n")
	if trimmed == "" {
		return 0
	}
	n := 1
	for _, r := range trimmed {
		if r == '\n' {
			n++
		}
	}
	return n
}

// finish fills in the fields every provider derives the same way, so the two
// real engines and the mock cannot drift apart on cost tier or line count.
func (r *Result) finish(provider Kind) {
	r.Provider = provider
	r.Lines = countLines(r.Text)
	r.CostTier = tierForLines(r.Lines)
}
