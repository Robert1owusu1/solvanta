package ocr

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
)

const visionGoodReply = `{
  "responses": [{
    "fullTextAnnotation": {
      "text": "Kwame wrote his name\nthen answered question one",
      "pages": [{"confidence": 0.91}, {"confidence": 0.79}]
    }
  }]
}`

// TestVisionBuildsTheDocumentedRequest checks the wire format against what
// Cloud Vision publishes: the annotate endpoint, DOCUMENT_TEXT_DETECTION, and
// the raw base64 body (no data-URL prefix, unlike Mathpix's src).
func TestVisionBuildsTheDocumentedRequest(t *testing.T) {
	stub := stubWith(visionGoodReply)
	p := NewVision("vision-key", stub)

	if _, err := p.Recognize(context.Background(), Input{
		Image: []byte{9, 9, 9}, ContentType: "image/jpeg",
	}); err != nil {
		t.Fatalf("Recognize: %v", err)
	}

	req := stub.req
	if req == nil {
		t.Fatal("no request was made")
	}
	if req.Method != http.MethodPost {
		t.Errorf("method = %s, want POST", req.Method)
	}
	if req.URL.Path != "/v1/images:annotate" {
		t.Errorf("path = %s", req.URL.Path)
	}

	var body visionRequest
	if err := json.Unmarshal(stub.body, &body); err != nil {
		t.Fatalf("body is not the documented request shape: %v", err)
	}
	if len(body.Requests) != 1 {
		t.Fatalf("requests = %d, want 1", len(body.Requests))
	}
	entry := body.Requests[0]
	if len(entry.Features) != 1 || entry.Features[0].Type != "DOCUMENT_TEXT_DETECTION" {
		t.Errorf("features = %+v, want DOCUMENT_TEXT_DETECTION", entry.Features)
	}
	if entry.Image.Content != base64.StdEncoding.EncodeToString([]byte{9, 9, 9}) {
		t.Error("image content is not the raw base64 of the photo")
	}
	if strings.HasPrefix(entry.Image.Content, "data:") {
		t.Error("Vision wants bare base64, not a data URL")
	}
	if entry.ImageContext == nil || len(entry.ImageContext.LanguageHints) == 0 {
		t.Error("no language hints: handwriting recognition degrades without them")
	}
}

// TestVisionKeepsTheApiKeyOutOfTheURL is a credential-handling assertion.
//
// Google accepts an API key either as ?key= or in X-Goog-Api-Key. The query
// string is worse here: the URL of a failed call is the first thing printed by
// an error, a proxy access log, and a panic trace. A key in a header appears
// in none of them.
func TestVisionKeepsTheApiKeyOutofTheURL(t *testing.T) {
	stub := stubWith(visionGoodReply)
	p := NewVision("super-secret-key", stub)

	if _, err := p.Recognize(context.Background(), Input{Image: []byte{1}}); err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	req := stub.req
	if got := req.Header.Get("X-Goog-Api-Key"); got != "super-secret-key" {
		t.Errorf("X-Goog-Api-Key = %q, want the key in the header", got)
	}
	if strings.Contains(req.URL.RawQuery, "super-secret-key") || strings.Contains(req.URL.String(), "super-secret-key") {
		t.Errorf("key leaked into the request URL: %s", req.URL)
	}
}

// TestVisionNormalisesTheReply proves the shared result shape holds for the
// second engine too, including averaging page-level confidence.
func TestVisionNormalisesTheReply(t *testing.T) {
	p := NewVision("key", stubWith(visionGoodReply))
	res, err := p.Recognize(context.Background(), Input{PageID: "PG-2", Image: []byte{1}})
	if err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	if res.Provider != KindVision {
		t.Errorf("Provider = %q, want %q", res.Provider, KindVision)
	}
	if res.Text != "Kwame wrote his name\nthen answered question one" {
		t.Errorf("Text = %q", res.Text)
	}
	// Averaged in floating point, so compared with a tolerance rather than
	// to the last bit: 0.91+0.79 is not exactly 1.7 in binary.
	if diff := res.Confidence - 0.85; diff > 1e-9 || diff < -1e-9 {
		t.Errorf("Confidence = %v, want 0.85 ((0.91+0.79)/2)", res.Confidence)
	}
	if res.Lines != 2 || res.CostTier != TierStandard {
		t.Errorf("Lines/CostTier = %d/%q", res.Lines, res.CostTier)
	}
	if len(res.Warnings) != 0 {
		t.Errorf("Warnings = %v, want none at 85%%", res.Warnings)
	}
}

// TestVisionMarksTheHigherRate mirrors the Mathpix tier test: the rate flag is
// a property of the line count, not of which engine read it.
func TestVisionMarksTheHigherRate(t *testing.T) {
	long := strings.Repeat("a line of homework\n", 20)
	reply := `{"responses":[{"fullTextAnnotation":{"text":` + mustJSON(long) + `}}]}`
	p := NewVision("key", stubWith(reply))

	res, err := p.Recognize(context.Background(), Input{Image: []byte{1}})
	if err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	if res.CostTier != TierHigh {
		t.Errorf("CostTier = %q, want %q", res.CostTier, TierHigh)
	}
}

// TestVisionAbsentConfidenceIsNotZero: Vision normally returns no page-level
// confidence for handwriting, so this is the everyday case, not an edge.
func TestVisionAbsentConfidenceIsNotZero(t *testing.T) {
	reply := `{"responses":[{"fullTextAnnotation":{"text":"some words"}}]}`
	p := NewVision("key", stubWith(reply))

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

// TestVisionFlagsALowReading so the confirmation screen has something to show
// before a teacher trusts the text.
func TestVisionFlagsALowReading(t *testing.T) {
	reply := `{"responses":[{"fullTextAnnotation":{"text":"scrawl","pages":[{"confidence":0.31}]}}]}`
	p := NewVision("key", stubWith(reply))

	res, err := p.Recognize(context.Background(), Input{Image: []byte{1}})
	if err != nil {
		t.Fatalf("Recognize: %v", err)
	}
	if len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "Low engine confidence") {
		t.Errorf("Warnings = %v", res.Warnings)
	}
}

// TestVisionTreatsNoTextAsAFailureAndNotAsAnEmptyAnswer is the anti-invented-
// data assertion for this provider: Vision answers 200 with no annotation for
// a blank or unreadable page, and an empty reading offered as success would be
// a fabricated answer.
func TestVisionTreatsNoTextAsAFailureAndNotAsAnEmptyAnswer(t *testing.T) {
	p := NewVision("key", stubWith(`{"responses":[{}]}`))
	_, err := p.Recognize(context.Background(), Input{PageID: "PG-7", Image: []byte{1}})
	if err == nil {
		t.Fatal("no text detected was reported as success")
	}
	if !strings.Contains(err.Error(), "PG-7") {
		t.Errorf("error should name the page: %v", err)
	}
}

// TestVisionSurfacesPerResponseError covers Vision reporting an error inside
// an HTTP 200 — the case a naive client reads as an empty success.
func TestVisionSurfacesPerResponseError(t *testing.T) {
	reply := `{"responses":[{"error":{"code":3,"message":"API key not valid"}}]}`
	p := NewVision("key", stubWith(reply))
	_, err := p.Recognize(context.Background(), Input{Image: []byte{1}})
	if err == nil || !strings.Contains(err.Error(), "API key not valid") {
		t.Errorf("err = %v", err)
	}
}

// TestVisionSurfacesHTTPFailure covers a transport-level rejection.
func TestVisionSurfacesHTTPFailure(t *testing.T) {
	p := NewVision("key", &httpStub{status: http.StatusTooManyRequests, payload: `{}`})
	_, err := p.Recognize(context.Background(), Input{Image: []byte{1}})
	if err == nil || !strings.Contains(err.Error(), "429") {
		t.Errorf("err = %v", err)
	}
}

// TestVisionRefusesEmptyPhoto matches Mathpix: no pointless round-trip.
func TestVisionRefusesEmptyPhoto(t *testing.T) {
	stub := stubWith(visionGoodReply)
	p := NewVision("key", stub)
	if _, err := p.Recognize(context.Background(), Input{}); !errors.Is(err, ErrNoImage) {
		t.Errorf("err = %v, want ErrNoImage", err)
	}
	if stub.req != nil {
		t.Error("a request was made despite having no image")
	}
}

// TestVisionKindReportsTruthfully keeps the startup log honest.
func TestVisionKindReportsTruthfully(t *testing.T) {
	if got := NewVision("key", stubWith("")).Kind(); got != KindVision {
		t.Errorf("Kind() = %q, want %q", got, KindVision)
	}
}
