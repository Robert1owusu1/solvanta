package ocr

import (
	"context"
	"sync"
)

// MockProvider is the no-network stand-in for both real engines.
//
// It exists so that the whole pipeline — routing, cost-tier logging, the
// question endpoint, the offline queue, the teacher confirmation step, and
// every test in between — can be built and proven with no API keys purchased.
// It never opens a socket and never inspects the photo, which also makes it
// the right default for local development on a laptop.
//
// Output is deterministic: the same input produces the same text every time,
// so a test can assert on it without stubbing anything. Where a test needs a
// specific answer instead, it configures one through [MockOption]s.
type MockProvider struct {
	mu sync.Mutex

	// text overrides the default text for every call.
	text string
	// math is set when the case is about math-notation output.
	math string
	// conf overrides the reported confidence.
	conf float64
	// confSet distinguishes "not configured" from "configured as zero".
	confSet bool
	// err, when set, is returned instead of a result — for exercising the
	// failure paths without breaking anything real.
	err error
	// queue feeds successive responses to successive calls, so a test can
	// walk a page through several states.
	queue []string

	calls int
	last  MockCall
}

// MockCall summarises the most recent Recognize, for assertions.
//
// It records how large the photo was rather than keeping the bytes: a mock
// that retained student images in memory would be a liability even in tests.
type MockCall struct {
	PageID      string
	SubjectID   string
	ContentType string
	ImageBytes  int
}

// MockOption configures a [MockProvider].
type MockOption func(*MockProvider)

// WithText makes the mock recognise [text] on every call.
func WithText(text string) MockOption {
	return func(m *MockProvider) { m.text = text }
}

// WithMath sets the structured-math output the mock returns, for cases about
// the math-notation route.
func WithMath(latex string) MockOption {
	return func(m *MockProvider) { m.math = latex }
}

// WithConfidence makes the mock report [c] (0..1) rather than the default.
func WithConfidence(c float64) MockOption {
	return func(m *MockProvider) {
		m.conf = c
		m.confSet = true
	}
}

// WithError makes every call fail with [err].
func WithError(err error) MockOption {
	return func(m *MockProvider) { m.err = err }
}

// WithQueue feeds one response per subsequent call, so a test can drive a
// page from pending through reviewed. Once exhausted it falls back to the
// configured text (or the default).
func WithQueue(texts ...string) MockOption {
	return func(m *MockProvider) { m.queue = append([]string(nil), texts...) }
}

// NewMock builds a mock provider.
func NewMock(opts ...MockOption) *MockProvider {
	m := &MockProvider{}
	for _, o := range opts {
		o(m)
	}
	return m
}

// Kind always reports KindMock — even while standing in for a paid route on a
// given subject.
//
// This is deliberate. Startup logging reads Kind(), and a mock claiming to be
// Mathpix would let a deployment print "math-notation: mathpix" while no key
// exists and no request would succeed. Reporting the truth costs a little
// convenience in test assertions and removes a genuinely misleading log line.
func (m *MockProvider) Kind() Kind { return KindMock }

// Recognize returns configured or default text. It never touches the network.
func (m *MockProvider) Recognize(_ context.Context, in Input) (*Result, error) {
	m.mu.Lock()
	m.calls++
	m.last = MockCall{
		PageID:      in.PageID,
		SubjectID:   in.SubjectID,
		ContentType: in.ContentType,
		ImageBytes:  len(in.Image),
	}
	if m.err != nil {
		err := m.err
		m.mu.Unlock()
		return nil, err
	}

	var text string
	switch {
	case len(m.queue) > 0:
		text = m.queue[0]
		m.queue = m.queue[1:]
	case m.text != "":
		text = m.text
	default:
		text = mockDefaultText(in)
	}
	latex := m.math
	conf, confSet := m.conf, m.confSet
	m.mu.Unlock()

	res := &Result{
		Text:       text,
		Math:       latex,
		Confidence: defaultConf(conf, confSet),
		RequestID:  "mock-" + in.PageID,
	}
	res.finish(KindMock)
	// The mock always reports a score, so unlike the real engines there is
	// never an "unreported" case — but a case configured as low confidence
	// must warn exactly as Mathpix and Vision would, or the confirmation
	// screen would behave differently against the mock than in production.
	res.Warnings = confidenceWarnings(res.Confidence, true)
	return res, nil
}

// Calls reports how many times Recognize ran.
func (m *MockProvider) Calls() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.calls
}

// LastCall summarises the most recent Recognize.
func (m *MockProvider) LastCall() MockCall {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.last
}

// defaultConf is the confidence reported when none was configured: high
// enough not to trip the low-confidence warning, and stable so a test's
// expected output does not move.
func defaultConf(c float64, set bool) float64 {
	if set {
		return c
	}
	return 0.93
}

// mockDefaultText is the recogniser output when nothing was configured.
//
// Deterministic in [in.PageID]: the same page always yields the same text, so
// a caller can assert on it. Obvious about what it is — a page id prefixed
// with "MOCK OCR" must never be mistaken for a real student's handwriting,
// and no fixture here should ever be able to leak into a marked grade.
func mockDefaultText(in Input) string {
	id := in.PageID
	if id == "" {
		id = "unidentified"
	}
	return "MOCK OCR — page " + id + "\n" +
		"Deterministic stand-in for a photographed page.\n" +
		"No external service was called and no key is required."
}
