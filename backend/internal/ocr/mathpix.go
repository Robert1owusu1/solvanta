package ocr

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// MathpixEndpoint is Mathpix's single-image OCR endpoint.
const MathpixEndpoint = "https://api.mathpix.com/v3/text"

// mathpixMaxBase64Bytes is Mathpix's documented ceiling on a base64-encoded
// image (~2 MB). It is checked before the request is built rather than left to
// the far end: a 413 from a vendor says nothing about which page failed, and a
// teacher re-photographing the same work three times does not help.
const mathpixMaxBase64Bytes = 2 << 20

// ImproveMathpix is the privacy flag sent on every request.
//
// It is sent as false on purpose, not because of a preference. Mathpix's
// default is true, which retains the submitted image for up to 90 days, caches
// the result, and makes the request retrievable through /v3/ocr-results — and
// hands it to their QA process. These are photographs of identifiable school
// children's work. Setting it false means the image is never written to disk
// and the result is never cached; the only copy is the response we receive.
//
// See backend/README.md ("Data privacy") before considering changing this.
const ImproveMathpix = false

// MathpixProvider reads math-notation content (equations, fractions) through
// Mathpix's /v3/text endpoint, normalising into [Result] exactly as
// [MockProvider] does — downstream code cannot tell them apart by shape.
//
// The credentials arrive once, at construction, and are held only in memory:
// they are never logged, never serialised, never put in a URL that a request
// log might capture.
type MathpixProvider struct {
	appID    string
	appKey   string
	client   Doer
	endpoint string
}

// NewMathpix builds a Mathpix provider. A nil [client] installs a default
// with a timeout — an unbounded HTTP call would leave a marking session
// hanging indefinitely on a stalled connection.
func NewMathpix(appID, appKey string, client Doer) *MathpixProvider {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	return &MathpixProvider{
		appID:    appID,
		appKey:   appKey,
		client:   client,
		endpoint: MathpixEndpoint,
	}
}

// Kind reports the engine this provider stands for.
func (m *MathpixProvider) Kind() Kind { return KindMathpix }

// mathpixRequest is the body sent to /v3/text.
//
// Two things in here are load-bearing rather than stylistic:
//
//   - Formats requests latex_styled alongside the Mathpix Markdown, so the
//     normalised Result carries plain text AND structured math when the page
//     has any. Asking for only one would force downstream to guess which it
//     got.
//   - Metadata sets improve_mathpix false, the retention opt-out described on
//     [ImproveMathpix]. This is the single most consequential field in the
//     request from a student-privacy standpoint.
type mathpixRequest struct {
	Src      string         `json:"src"`
	Formats  []string       `json:"formats"`
	RmSpaces bool           `json:"rm_spaces"`
	Metadata map[string]any `json:"metadata"`
}

// mathpixResponse is the subset of /v3/text's reply this pipeline uses.
//
// Confidence is a pointer because Mathpix omits it on some replies: a missing
// field must read as "engine did not score this" rather than as a confident
// zero, and the two mean very different things to a teacher deciding whether
// to trust a reading.
type mathpixResponse struct {
	RequestID      string   `json:"request_id"`
	Text           string   `json:"text"`
	LaTeXStyled    string   `json:"latex_styled"`
	Confidence     *float64 `json:"confidence"`
	ConfidenceRate *float64 `json:"confidence_rate"`
	Error          string   `json:"error"`
}

// Recognize sends one image to Mathpix and normalises the reply.
func (m *MathpixProvider) Recognize(ctx context.Context, in Input) (*Result, error) {
	if len(in.Image) == 0 {
		return nil, ErrNoImage
	}

	encoded := base64.StdEncoding.EncodeToString(in.Image)
	src := "data:" + contentTypeFor(in) + ";base64," + encoded
	if len(src) > mathpixMaxBase64Bytes {
		return nil, fmt.Errorf(
			"ocr: page %s is %d bytes base64 but mathpix accepts at most %d — the page needs to be downscaled before it is sent",
			pageLabel(in), len(src), mathpixMaxBase64Bytes)
	}

	body, err := json.Marshal(mathpixRequest{
		Src:      src,
		Formats:  []string{"text", "latex_styled"},
		RmSpaces: true,
		Metadata: map[string]any{"improve_mathpix": ImproveMathpix},
	})
	if err != nil {
		return nil, fmt.Errorf("ocr: encode mathpix request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("ocr: build mathpix request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("app_id", m.appID)
	req.Header.Set("app_key", m.appKey)

	start := time.Now()
	httpResp, err := m.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ocr: mathpix: %w", err)
	}
	defer func() { _ = httpResp.Body.Close() }()

	raw, err := io.ReadAll(io.LimitReader(httpResp.Body, 8<<20))
	if err != nil {
		return nil, fmt.Errorf("ocr: mathpix: read reply: %w", err)
	}

	var reply mathpixResponse
	if err := json.Unmarshal(raw, &reply); err != nil {
		return nil, fmt.Errorf("ocr: mathpix: unparseable reply (status %d): %w", httpResp.StatusCode, err)
	}
	if reply.Error != "" {
		return nil, fmt.Errorf("ocr: mathpix: %s", reply.Error)
	}
	if httpResp.StatusCode < 200 || httpResp.StatusCode >= 300 {
		return nil, fmt.Errorf("ocr: mathpix: status %d: %s", httpResp.StatusCode, truncate(string(raw), 300))
	}

	res := &Result{
		Text:       reply.Text,
		Math:       reply.LaTeXStyled,
		RequestID:  reply.RequestID,
		DurationMS: time.Since(start).Milliseconds(),
	}
	if reply.Confidence != nil {
		res.Confidence = *reply.Confidence
	}
	res.finish(KindMathpix)
	res.Warnings = confidenceWarnings(res.Confidence, reply.Confidence != nil)
	return res, nil
}

// confidenceWarnings turns an unreadable score into something the teacher
// confirmation step can show. Only a score that was actually reported can be
// judged — an absent one is reported as such instead of being guessed at.
func confidenceWarnings(conf float64, reported bool) []string {
	if !reported {
		return []string{"The engine did not report a confidence score for this page."}
	}
	if conf < 0.6 {
		return []string{fmt.Sprintf(
			"Low engine confidence (%.0f%%) — check this page's reading against the photo before accepting it.",
			conf*100)}
	}
	return nil
}

// pageLabel names a page for an error message without echoing anything about
// the student. An empty id still has to say something useful.
func pageLabel(in Input) string {
	if in.PageID != "" {
		return in.PageID
	}
	return "unidentified"
}

// truncate shortens text for an error message so a vendor's 40KB HTML error
// page does not become our log line.
func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
