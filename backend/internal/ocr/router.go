package ocr

import (
	"fmt"
	"strings"
)

// isMathSubject reports whether [subjectID] defaults to math-notation OCR.
//
// The subject list is a fixed client-side enum (there is no subjects table to
// hang a column on), so the mapping lives here rather than in the schema.
// Integrating Science and the rest stay on plain-text OCR by default and reach
// Mathpix through the question-level override when an individual question does
// carry equations.
func isMathSubject(subjectID string) bool {
	switch strings.ToUpper(strings.TrimSpace(subjectID)) {
	case "MATH", "MATHS", "MATHEMATICS":
		return true
	}
	return false
}

// routeFor picks the provider kind for one piece of content.
//
// An explicit override wins over the subject default — that is the whole
// point of it: a mixed subject such as Integrated Science sends most pages to
// Vision but can send one equation-bearing question to Mathpix. A malformed
// override is ignored rather than honoured, because guessing an engine for a
// student's answer is not a failure mode worth having.
func routeFor(subjectID, override string) Kind {
	if o := Kind(strings.TrimSpace(override)); o != "" && o.valid() {
		return o
	}
	if isMathSubject(subjectID) {
		return KindMathpix
	}
	return KindVision
}

// fallback is handed out when a Router was never built. Building a fresh mock
// per call would be wasteful; returning nil would panic the request path.
var fallback = NewMock()

// Router serves the right provider for a given piece of content.
//
// It holds at most three providers: whatever serves math notation, whatever
// serves plain text, and the mock that stands in for either when credentials
// are missing. In a deployment with no keys — the current state — both routes
// point at the same mock, and the process still boots and answers.
type Router struct {
	math   Provider
	text   Provider
	mock   Provider
	status string
}

// NewRouter builds the router from [cfg], falling back to MockProvider for
// any route whose credentials are incomplete.
//
// "Incomplete" is deliberate: Mathpix needs BOTH an app id and an app key, so
// half-configured credentials fall back rather than half-working in
// production and failing only on the first student's page.
func NewRouter(cfg Config) *Router {
	mock := NewMock()

	mathP, mathWhy := Provider(mock), ""
	if cfg.MathpixReady() {
		mathP, mathWhy = NewMathpix(cfg.MathpixAppID, cfg.MathpixAppKey, nil), "credentials present"
	} else {
		mathWhy = "MATHPIX_APP_ID/MATHPIX_APP_KEY unset"
	}

	textP, textWhy := Provider(mock), ""
	if cfg.VisionReady() {
		textP, textWhy = NewVision(cfg.VisionAPIKey, nil), "credentials present"
	} else {
		textWhy = "GOOGLE_VISION_API_KEY unset"
	}

	return &Router{
		math:  mathP,
		text:  textP,
		mock:  mock,
		status: fmt.Sprintf("OCR routes — math-notation: %s (%s) · plain-text: %s (%s)",
			mathP.Kind(), mathWhy, textP.Kind(), textWhy),
	}
}

// NewRouterWith builds a router from providers handed in by the caller.
//
// This is the seam that lets the server's routing be proven rather than
// assumed: a test can stand a recogniser in for each route, with no
// credentials and no network, and assert that subject-level routing, the
// question-level override, and the image itself all reached the provider the
// router picked. Production paths use [NewRouter], which remains the only
// place credentials are read from the environment.
func NewRouterWith(mathP, textP Provider) *Router {
	if mathP == nil {
		mathP = fallback
	}
	if textP == nil {
		textP = fallback
	}
	return &Router{
		math:   mathP,
		text:   textP,
		mock:   fallback,
		status: "OCR routes — math-notation: " + string(mathP.Kind()) + " (supplied) · plain-text: " + string(textP.Kind()) + " (supplied)",
	}
}

// Provider returns the provider that should handle content for [subjectID],
// unless [override] names one explicitly.
//
// The override is the question-level escape hatch for mixed subjects. It is
// never allowed to name an engine that does not exist — see [routeFor].
func (r *Router) Provider(subjectID, override string) Provider {
	if r == nil {
		return fallback
	}
	switch routeFor(subjectID, override) {
	case KindMathpix:
		return r.math
	case KindVision:
		return r.text
	default:
		return r.mock
	}
}

// Status is the one-line startup summary of which engine serves which route
// and why. Printed once at boot so nobody has to guess whether a key took.
func (r *Router) Status() string {
	if r == nil {
		return "OCR routes — math-notation: mock · plain-text: mock"
	}
	return r.status
}
