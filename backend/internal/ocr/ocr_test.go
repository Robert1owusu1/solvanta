package ocr

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// --- MockProvider -----------------------------------------------------------

// TestMockIsDeterministic pins the property the whole phase leans on: the same
// input gives byte-identical output, every time, in any process. Without it a
// test asserting on mock text would be asserting on a rumour.
func TestMockIsDeterministic(t *testing.T) {
	in := Input{PageID: "SUB-42", SubjectID: "MATH"}
	first := NewMock()
	second := NewMock()

	a, err := first.Recognize(context.Background(), in)
	if err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	for i := 0; i < 5; i++ {
		got, err := second.Recognize(context.Background(), in)
		if err != nil {
			t.Fatalf("Recognize: %v", err)
		}
		if got.Text != a.Text {
			t.Fatalf("not deterministic: run 0 = %q, run %d = %q", a.Text, i, got.Text)
		}
	}
}

// TestMockTextIsObviouslySynthetic guards the one property that keeps a mock
// reading from ever being mistaken for a student's: it says what it is.
func TestMockTextIsObviouslySynthetic(t *testing.T) {
	res, err := NewMock().Recognize(context.Background(), Input{PageID: "P1"})
	if err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	if !strings.Contains(res.Text, "MOCK OCR") {
		t.Errorf("mock output does not identify itself as mock: %q", res.Text)
	}
}

// TestMockIsConfigurablePerCase covers the options a test needs to drive the
// pipeline through states the default text cannot reach.
func TestMockIsConfigurablePerCase(t *testing.T) {
	t.Run("fixed text", func(t *testing.T) {
		m := NewMock(WithText("fixed reading"))
		res, err := m.Recognize(context.Background(), Input{})
		if err != nil {
			t.Fatalf("Recognize: %v", err)
		}
		if res.Text != "fixed reading" {
			t.Errorf("Text = %q", res.Text)
		}
	})

	t.Run("queue feeds successive calls", func(t *testing.T) {
		m := NewMock(WithQueue("first", "second"))
		ctx := context.Background()
		for _, want := range []string{"first", "second"} {
			res, err := m.Recognize(ctx, Input{})
			if err != nil {
				t.Fatalf("Recognize: %v", err)
			}
			if res.Text != want {
				t.Errorf("Text = %q, want %q", res.Text, want)
			}
		}
		// Exhausted: falls back to the default rather than returning nothing.
		res, err := m.Recognize(ctx, Input{})
		if err != nil {
			t.Fatalf("Recognize: %v", err)
		}
		if res.Text == "" {
			t.Error("empty text after queue exhaustion")
		}
	})

	t.Run("error path", func(t *testing.T) {
		want := errors.New("engine down")
		m := NewMock(WithError(want))
		if _, err := m.Recognize(context.Background(), Input{}); !errors.Is(err, want) {
			t.Errorf("err = %v, want %v", err, want)
		}
	})

	t.Run("low confidence warns", func(t *testing.T) {
		m := NewMock(WithConfidence(0.31))
		res, err := m.Recognize(context.Background(), Input{})
		if err != nil {
			t.Fatalf("Recognize: %v", err)
		}
		if len(res.Warnings) == 0 {
			t.Fatal("a 31% confidence produced no warning for the confirmation screen")
		}
		if !strings.Contains(res.Warnings[0], "31%") {
			t.Errorf("warning = %q", res.Warnings[0])
		}
	})

	t.Run("high confidence does not nag", func(t *testing.T) {
		m := NewMock(WithConfidence(0.97))
		res, err := m.Recognize(context.Background(), Input{})
		if err != nil {
			t.Fatalf("Recognize: %v", err)
		}
		if len(res.Warnings) != 0 {
			t.Errorf("warnings = %v, want none", res.Warnings)
		}
	})
}

// TestMockNeverClaimsToBeAPaidEngine is a safety net on startup honesty: the
// mock reporting KindMathpix would let a deployment with no key print
// "math-notation: mathpix" at boot and then fail on every real request.
func TestMockNeverClaimsToBeAPaidEngine(t *testing.T) {
	if got := NewMock().Kind(); got != KindMock {
		t.Errorf("Kind() = %q, want %q", got, KindMock)
	}
}

// TestMockRecordsInputWithoutKeepingThePhoto checks the mock learns what it
// was asked about while retaining no image bytes: a helper that held student
// photos in memory would be a liability even inside tests.
func TestMockRecordsInputWithoutKeepingThePhoto(t *testing.T) {
	m := NewMock()
	img := make([]byte, 1024)
	if _, err := m.Recognize(context.Background(), Input{
		PageID: "PG-1", SubjectID: "SCI", ContentType: "image/png", Image: img,
	}); err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	call := m.LastCall()
	if call.PageID != "PG-1" || call.SubjectID != "SCI" || call.ContentType != "image/png" {
		t.Errorf("recorded = %+v", call)
	}
	if call.ImageBytes != len(img) {
		t.Errorf("ImageBytes = %d, want %d", call.ImageBytes, len(img))
	}
}

// --- Routing ----------------------------------------------------------------

// TestRouteFor pins the routing rule itself: Maths defaults to math notation,
// everything else to plain handwriting, and an explicit override wins.
func TestRouteFor(t *testing.T) {
	cases := []struct {
		name     string
		subject  string
		override string
		want     Kind
	}{
		{"maths defaults to math notation", "MATH", "", KindMathpix},
		{"maths is matched case-insensitively", "math", "", KindMathpix},
		{"mathematics alias", "Mathematics", "", KindMathpix},
		{"science defaults to plain text", "SCI", "", KindVision},
		{"english defaults to plain text", "ENG", "", KindVision},
		{"social studies defaults to plain text", "SOC", "", KindVision},
		{"rme defaults to plain text", "RME", "", KindVision},
		{"ict defaults to plain text", "ICT", "", KindVision},
		// The mixed-subject case: one equation-bearing question inside a
		// plain-text subject reaches Mathpix only because of the override.
		{"override lifts a science page to math", "SCI", "mathpix", KindMathpix},
		{"override can also send maths to plain text", "MATH", "google_vision", KindVision},
		{"override may name the mock", "MATH", "mock", KindMock},
		// A malformed override must not decide anything for a student's page.
		{"unknown override falls back to subject default", "MATH", "nonsense", KindMathpix},
		{"unknown override on plain subject stays plain", "SCI", "nonsense", KindVision},
		{"blank override is ignored", "SCI", "   ", KindVision},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := routeFor(tc.subject, tc.override); got != tc.want {
				t.Errorf("routeFor(%q, %q) = %q, want %q", tc.subject, tc.override, got, tc.want)
			}
		})
	}
}

// TestNewRouterFallsBackToMockWithoutKeys is the "runs fully without keys"
// guarantee: no credentials must mean a working router on the mock, not a
// panic and not an error at construction.
func TestNewRouterFallsBackToMockWithoutKeys(t *testing.T) {
	r := NewRouter(Config{})
	ctx := context.Background()

	for _, subject := range []string{"MATH", "SCI", "ENG", "SOC", "ICT", "RME"} {
		p := r.Provider(subject, "")
		if p == nil {
			t.Fatalf("Provider(%q) = nil", subject)
		}
		if p.Kind() != KindMock {
			t.Errorf("Provider(%q).Kind() = %q, want %q with no keys", subject, p.Kind(), KindMock)
		}
		// And it must actually produce output, not just exist.
		res, err := p.Recognize(ctx, Input{PageID: "P"})
		if err != nil || res == nil || res.Text == "" {
			t.Fatalf("Provider(%q) did not produce a reading: res=%v err=%v", subject, res, err)
		}
	}
}

// TestRouterStatusSaysWhy checks the startup line names the active engine AND
// the reason, so an unset key is visible rather than silent.
func TestRouterStatusSaysWhy(t *testing.T) {
	status := NewRouter(Config{}).Status()
	for _, want := range []string{"math-notation", "plain-text", "mock", "MATHPIX_APP_ID", "GOOGLE_VISION_API_KEY"} {
		if !strings.Contains(status, want) {
			t.Errorf("status %q is missing %q", status, want)
		}
	}
}

// TestNewRouterPromotesRoutesWithKeys proves both halves of the flag: supply
// credentials and that route leaves the mock for the real engine. Construction
// makes no network call, so this is safe with no key material at all.
func TestNewRouterPromotesRoutesWithKeys(t *testing.T) {
	r := NewRouter(Config{
		MathpixAppID:  "id",
		MathpixAppKey: "key",
		VisionAPIKey:  "key",
	})
	if got := r.Provider("MATH", "").Kind(); got != KindMathpix {
		t.Errorf("math route = %q, want %q", got, KindMathpix)
	}
	if got := r.Provider("SCI", "").Kind(); got != KindVision {
		t.Errorf("text route = %q, want %q", got, KindVision)
	}
	status := r.Status()
	if strings.Contains(status, "unset") {
		t.Errorf("status still reports unset keys: %q", status)
	}
}

// TestHalfConfiguredCredentialsStayOnTheMock: one of two Mathpix fields set is
// not "half working", it is broken at the first real request. Better to stay
// on the mock, where it is visibly a mock, than to fail on a student's page.
func TestHalfConfiguredCredentialsStayOnTheMock(t *testing.T) {
	r := NewRouter(Config{MathpixAppID: "id-only"})
	if got := r.Provider("MATH", "").Kind(); got != KindMock {
		t.Errorf("half-configured math route = %q, want %q", got, KindMock)
	}
}

// TestNilRouterStillServes: a Server built without NewServer must not panic on
// the request path.
func TestNilRouterStillServes(t *testing.T) {
	var r *Router
	if got := r.Provider("MATH", "").Kind(); got != KindMock {
		t.Errorf("nil router = %q, want %q", got, KindMock)
	}
	if r.Status() == "" {
		t.Error("nil router status is empty")
	}
}

// --- Cost tiers -------------------------------------------------------------

// TestCostTierThreshold pins the billing boundary at exactly 12 lines: the
// tier changes on the 13th, not the 12th, and getting this wrong bills a
// school for pages it did not push over.
func TestCostTierThreshold(t *testing.T) {
	cases := []struct {
		lines int
		want  CostTier
	}{
		{0, TierStandard},
		{1, TierStandard},
		{12, TierStandard}, // exactly at the threshold: still the base rate
		{13, TierHigh},     // one over: the higher rate applies
		{40, TierHigh},
	}
	for _, tc := range cases {
		if got := tierForLines(tc.lines); got != tc.want {
			t.Errorf("tierForLines(%d) = %q, want %q", tc.lines, got, tc.want)
		}
	}
}

// TestCountLinesIgnoresTrailingNewline: an engine that terminates every line
// must not push a 12-line page to 13 and bill it at the higher rate for a
// formatting habit.
func TestCountLinesIgnoresTrailingNewline(t *testing.T) {
	body := "one\ntwo\nthree"
	cases := map[string]int{
		"":                              0,
		"single":                        1,
		body:                            3,
		body + "\n":                     3,
		body + "\n\n\n":                 3,
		"one\r\ntwo\r\nthree":           3,
		"\n":                            0,
		strings.Repeat("x\n", 12) + "x": 13,
	}
	for in, want := range cases {
		if got := countLines(in); got != want {
			t.Errorf("countLines(%q) = %d, want %d", in, got, want)
		}
	}
}

// TestResultFinishDerivesSharedFields: all three providers route through
// finish(), so a provider cannot quietly report a different line count or rate
// for the same text than its siblings would.
func TestResultFinishDerivesSharedFields(t *testing.T) {
	res := &Result{Text: "a\nb\nc\nd"}
	res.finish(KindMathpix)
	if res.Lines != 4 {
		t.Errorf("Lines = %d, want 4", res.Lines)
	}
	if res.CostTier != TierStandard {
		t.Errorf("CostTier = %q, want %q", res.CostTier, TierStandard)
	}
	if res.Provider != KindMathpix {
		t.Errorf("Provider = %q, want %q", res.Provider, KindMathpix)
	}
}

// TestConfidenceWarnings covers the contract with the confirmation screen: an
// unreported score must be described as unreported, never as zero.
func TestConfidenceWarnings(t *testing.T) {
	if w := confidenceWarnings(0, false); len(w) != 1 || !strings.Contains(w[0], "did not report") {
		t.Errorf("unreported warnings = %v", w)
	}
	if w := confidenceWarnings(0.2, true); len(w) != 1 || !strings.Contains(w[0], "Low engine confidence") {
		t.Errorf("low warnings = %v", w)
	}
	if w := confidenceWarnings(0.9, true); w != nil {
		t.Errorf("high confidence warnings = %v, want nil", w)
	}
}
