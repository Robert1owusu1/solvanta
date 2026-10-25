package ocr

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
)

const mathpixGoodReply = `{
  "request_id": "mp-req-1",
  "text": "\\(x^{2}+1\\)",
  "latex_styled": "x^{2}+1",
  "confidence": 0.87,
  "confidence_rate": 0.9
}`

// TestMathpixBuildsTheDocumentedRequest checks the wire format against what
// Mathpix publishes: endpoint, both credential headers, the formats that give
// downstream plain text AND structured math, and the base64 data-URL src.
func TestMathpixBuildsTheDocumentedRequest(t *testing.T) {
	stub := stubWith(mathpixGoodReply)
	p := NewMathpix("my-app-id", "my-app-key", stub)

	if _, err := p.Recognize(context.Background(), Input{
		PageID: "PG-9", Image: []byte{1, 2, 3, 4}, ContentType: "image/png",
	}); err != nil {
		t.Fatalf("Recognize: %v", err)
	}

	if stub.req == nil {
		t.Fatal("no request was made")
	}
	if stub.req.Method != http.MethodPost {
		t.Errorf("method = %s, want POST", stub.req.Method)
	}
	if got := stub.req.URL.String(); got != MathpixEndpoint {
		t.Errorf("url = %s, want %s", got, MathpixEndpoint)
	}
	if got := stub.req.Header.Get("app_id"); got != "my-app-id" {
		t.Errorf("app_id = %q", got)
	}
	if got := stub.req.Header.Get("app_key"); got != "my-app-key" {
		t.Errorf("app_key = %q", got)
	}

	var body mathpixRequest
	if err := json.Unmarshal(stub.body, &body); err != nil {
		t.Fatalf("body is not the documented request shape: %v", err)
	}
	if !strings.HasPrefix(body.Src, "data:image/png;base64,") {
		t.Errorf("src prefix = %q, want a data URL carrying the content type", body.Src)
	}
	wantFormats := map[string]bool{"text": false, "latex_styled": false}
	for _, f := range body.Formats {
		if _, ok := wantFormats[f]; ok {
			wantFormats[f] = true
		}
	}
	if !wantFormats["text"] || !wantFormats["latex_styled"] {
		t.Errorf("formats = %v, want both text and latex_styled so downstream gets plain text and math", body.Formats)
	}
	if !body.RmSpaces {
		t.Error("rm_spaces should be set")
	}
}

// TestMathpixDisablesImprovementOptOut is the privacy-critical assertion of
// this phase.
//
// Mathpix's DEFAULT is improve_mathpix: true, which writes the submitted image
// to disk for up to 90 days, caches the OCR result, and makes the request
// retrievable through /v3/ocr-results. These are photographs of identifiable
// schoolchildren's work. Flipping this flag to true — deliberately, or by a
// refactor that drops the metadata — would silently re-enable retention on
// student pages, so it is asserted directly rather than trusted.
func TestMathpixDisablesImprovementOptOut(t *testing.T) {
	stub := stubWith(mathpixGoodReply)
	p := NewMathpix("id", "key", stub)

	if _, err := p.Recognize(context.Background(), Input{Image: []byte{1}}); err != nil {
		t.Fatalf("Recognize: %v", err)
	}

	var raw map[string]any
	if err := json.Unmarshal(stub.body, &raw); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}
	meta, ok := raw["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("no metadata object in request: %s", stub.body)
	}
	if got, ok := meta["improve_mathpix"]; !ok {
		t.Fatal("metadata.improve_mathpix is absent — absent means Mathpix's default of TRUE, i.e. retention on")
	} else if got != false {
		t.Fatalf("improve_mathpix = %v, want false (retention must be off for student pages)", got)
	}
	if ImproveMathpix {
		t.Fatal("ImproveMathpix const must stay false; see its comment")
	}
}

// TestMathpixNormalisesTheReply covers the whole point of the interface: the
// provider's output shape is the shared one, so nothing downstream can tell
// which engine produced it.
func TestMathpixNormalisesTheReply(t *testing.T) {
	p := NewMathpix("id", "key", stubWith(mathpixGoodReply))
	res, err := p.Recognize(context.Background(), Input{PageID: "PG-9", Image: []byte{1}})
	if err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	if res.Provider != KindMathpix {
		t.Errorf("Provider = %q, want %q", res.Provider, KindMathpix)
	}
	if res.Text != `\(x^{2}+1\)` {
		t.Errorf("Text = %q", res.Text)
	}
	if res.Math != "x^{2}+1" {
		t.Errorf("Math = %q", res.Math)
	}
	if res.Confidence != 0.87 {
		t.Errorf("Confidence = %v, want 0.87", res.Confidence)
	}
	if res.RequestID != "mp-req-1" {
		t.Errorf("RequestID = %q", res.RequestID)
	}
	if res.Lines != 1 || res.CostTier != TierStandard {
		t.Errorf("Lines/CostTier = %d/%q", res.Lines, res.CostTier)
	}
	if len(res.Warnings) != 0 {
		t.Errorf("Warnings = %v, want none at 87%%", res.Warnings)
	}
}

// TestMathpixMarksTheHigherRate when a page crosses the line threshold: the
// tier must reach the caller so the cost log can name it.
func TestMathpixMarksTheHigherRate(t *testing.T) {
	long := strings.Repeat("a line of homework\n", 20)
	reply := `{"text":` + mustJSON(long) + `,"confidence":0.9}`
	p := NewMathpix("id", "key", stubWith(reply))

	res, err := p.Recognize(context.Background(), Input{Image: []byte{1}})
	if err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	if res.Lines <= MathpixHighRateLines {
		t.Fatalf("Lines = %d, want more than %d", res.Lines, MathpixHighRateLines)
	}
	if res.CostTier != TierHigh {
		t.Errorf("CostTier = %q, want %q", res.CostTier, TierHigh)
	}
}

// TestMathpixAbsentConfidenceIsNotZero: Mathpix omits confidence on some
// replies. A missing field reported as a confident 0% would tell the teacher
// the page is illegible when the engine in fact offered no judgement.
func TestMathpixAbsentConfidenceIsNotZero(t *testing.T) {
	p := NewMathpix("id", "key", stubWith(`{"text":"hello","request_id":"r"}`))
	res, err := p.Recognize(context.Background(), Input{Image: []byte{1}})
	if err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	if res.Confidence != 0 {
		t.Errorf("Confidence = %v, want 0 for an absent field", res.Confidence)
	}
	if len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "did not report") {
		t.Errorf("Warnings = %v, want an explicit not-reported warning", res.Warnings)
	}
}

// TestMathpixRefusesEmptyPhoto: ErrNoImage must not become a pointless
// round-trip that bills for nothing.
func TestMathpixRefusesEmptyPhoto(t *testing.T) {
	stub := stubWith(mathpixGoodReply)
	p := NewMathpix("id", "key", stub)
	if _, err := p.Recognize(context.Background(), Input{}); !errors.Is(err, ErrNoImage) {
		t.Errorf("err = %v, want ErrNoImage", err)
	}
	if stub.req != nil {
		t.Error("a request was made despite having no image")
	}
}

// TestMathpixRejectsOversizeImageBeforeSending enforces the documented 2 MB
// base64 ceiling locally, with a message a person can act on. Left to the
// vendor it fails as an unexplained 413 naming no page, and a teacher
// re-photographing the same work does not fix a size limit.
func TestMathpixRejectsOversizeImageBeforeSending(t *testing.T) {
	stub := stubWith(mathpixGoodReply)
	p := NewMathpix("id", "key", stub)

	huge := make([]byte, 2<<20)
	_, err := p.Recognize(context.Background(), Input{PageID: "PG-3", Image: huge})
	if err == nil {
		t.Fatal("oversize image was accepted")
	}
	if stub.req != nil {
		t.Error("request was sent despite exceeding the limit")
	}
	if !strings.Contains(err.Error(), "downscale") {
		t.Errorf("error should say what to do: %v", err)
	}
	if !strings.Contains(err.Error(), "PG-3") {
		t.Errorf("error should name the page: %v", err)
	}
}

// TestMathpixSurfacesVendorError: a Mathpix error string must reach the caller
// rather than parsing into an empty-but-successful reading.
func TestMathpixSurfacesVendorError(t *testing.T) {
	p := NewMathpix("id", "key", stubWith(`{"error":"not authorized"}`))
	_, err := p.Recognize(context.Background(), Input{Image: []byte{1}})
	if err == nil || !strings.Contains(err.Error(), "not authorized") {
		t.Errorf("err = %v", err)
	}
}

// TestMathpixSurfacesHTTPFailure: a non-2xx must not be mistaken for text.
func TestMathpixSurfacesHTTPFailure(t *testing.T) {
	p := NewMathpix("id", "key", &httpStub{
		status:  http.StatusUnauthorized,
		payload: `<html>401</html>`,
	})
	_, err := p.Recognize(context.Background(), Input{Image: []byte{1}})
	if err == nil || !strings.Contains(err.Error(), "401") {
		t.Errorf("err = %v", err)
	}
}

// TestMathpixKindReportsTruthfully keeps the startup log honest.
func TestMathpixKindReportsTruthfully(t *testing.T) {
	if got := NewMathpix("id", "key", stubWith("")).Kind(); got != KindMathpix {
		t.Errorf("Kind() = %q, want %q", got, KindMathpix)
	}
}

// mustJSON quotes a string as a JSON literal for building reply fixtures.
func mustJSON(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return string(b)
}
