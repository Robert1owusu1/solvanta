package ocr

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// GoogleVisionEndpoint is Cloud Vision's synchronous annotation endpoint.
const GoogleVisionEndpoint = "https://vision.googleapis.com/v1/images:annotate"

// visionLanguageHints tells Vision it is looking at handwriting.
//
// The second hint is Google's own handwriting descriptor; without it the
// plain-text model leans on printed-letter statistics and misreads the exact
// cursive this pipeline exists to read. Hints are advisory — a wrong hint
// degrades a result rather than failing a request — but this pair has not been
// exercised against a real photo of a Ghanaian classroom yet, because no key
// exists. It is called out as unverified in the Phase 4 report rather than
// being claimed as working.
var visionLanguageHints = []string{"en", "en-t-i0-handwrit"}

// VisionProvider reads plain handwriting through Cloud Vision's
// DOCUMENT_TEXT_DETECTION, normalising into [Result] exactly as
// [MockProvider] does.
//
// The API key is sent in the X-Goog-Api-Key header rather than the usual
// ?key= query parameter. Google accepts both, and the header is materially
// better here: a query-string key lands in the URL, and the URL of a failed
// call is the first thing that appears in an error string, a proxy access log,
// and a panic trace. Header keys do not.
type VisionProvider struct {
	apiKey   string
	client   Doer
	endpoint string
}

// NewVision builds a Cloud Vision provider. A nil [client] installs a default
// with a timeout.
func NewVision(apiKey string, client Doer) *VisionProvider {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	return &VisionProvider{apiKey: apiKey, client: client, endpoint: GoogleVisionEndpoint}
}

// Kind reports the engine this provider stands for.
func (v *VisionProvider) Kind() Kind { return KindVision }

// visionRequest is the body sent to images:annotate.
type visionRequest struct {
	Requests []visionRequestEntry `json:"requests"`
}

type visionRequestEntry struct {
	Image       visionImage        `json:"image"`
	Features    []visionFeature    `json:"features"`
	ImageContext *visionImageContext `json:"imageContext,omitempty"`
}

type visionImage struct {
	// Content is the raw base64 of the photo, per Vision's contract (no
	// data-URL prefix, unlike Mathpix's src).
	Content string `json:"content"`
}

type visionFeature struct {
	Type       string `json:"type"`
	MaxResults int    `json:"maxResults"`
}

type visionImageContext struct {
	LanguageHints []string `json:"languageHints"`
}

// visionResponse is the subset of the reply this pipeline uses.
type visionResponse struct {
	Responses []visionResponseEntry `json:"responses"`
}

type visionResponseEntry struct {
	Error              *visionError       `json:"error"`
	FullTextAnnotation *visionFullTextAnn `json:"fullTextAnnotation"`
}

type visionError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type visionFullTextAnn struct {
	Text  string       `json:"text"`
	Pages []visionPage `json:"pages"`
}

type visionPage struct {
	// Confidence is a pointer: Vision commonly omits page-level confidence
	// for handwriting, and a missing value must not be read as zero.
	Confidence *float64 `json:"confidence"`
}

// Recognize sends one image to Cloud Vision and normalises the reply.
func (v *VisionProvider) Recognize(ctx context.Context, in Input) (*Result, error) {
	if len(in.Image) == 0 {
		return nil, ErrNoImage
	}

	body, err := json.Marshal(visionRequest{
		Requests: []visionRequestEntry{{
			Image: visionImage{Content: base64.StdEncoding.EncodeToString(in.Image)},
			Features: []visionFeature{{
				Type:       "DOCUMENT_TEXT_DETECTION",
				MaxResults: 1,
			}},
			ImageContext: &visionImageContext{LanguageHints: visionLanguageHints},
		}},
	})
	if err != nil {
		return nil, fmt.Errorf("ocr: encode vision request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, v.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("ocr: build vision request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Goog-Api-Key", v.apiKey)

	start := time.Now()
	httpResp, err := v.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ocr: vision: %w", err)
	}
	defer func() { _ = httpResp.Body.Close() }()

	raw, err := io.ReadAll(io.LimitReader(httpResp.Body, 8<<20))
	if err != nil {
		return nil, fmt.Errorf("ocr: vision: read reply: %w", err)
	}
	if httpResp.StatusCode < 200 || httpResp.StatusCode >= 300 {
		return nil, fmt.Errorf("ocr: vision: status %d: %s", httpResp.StatusCode, truncate(string(raw), 300))
	}

	var reply visionResponse
	if err := json.Unmarshal(raw, &reply); err != nil {
		return nil, fmt.Errorf("ocr: vision: unparseable reply: %w", err)
	}
	if len(reply.Responses) == 0 {
		return nil, fmt.Errorf("ocr: vision: reply carried no responses")
	}
	entry := reply.Responses[0]
	if entry.Error != nil {
		return nil, fmt.Errorf("ocr: vision: %s (code %d)", entry.Error.Message, entry.Error.Code)
	}
	if entry.FullTextAnnotation == nil {
		// A blank or unreadable page: Vision answers 200 with nothing in it.
		// That is a real outcome, not an error — but it must reach the
		// teacher's confirmation screen as "nothing was read", never as an
		// empty-but-valid answer.
		return nil, fmt.Errorf("ocr: vision: no text detected on page %s", pageLabel(in))
	}

	res := &Result{
		Text:       entry.FullTextAnnotation.Text,
		RequestID:  "",
		DurationMS: time.Since(start).Milliseconds(),
	}
	res.Confidence, res.Warnings = aggregatePageConfidence(entry.FullTextAnnotation.Pages)
	res.finish(KindVision)
	return res, nil
}

// aggregatePageConfidence averages the page-level scores Vision actually
// returned.
//
// When it returned none — the usual case for handwriting — the second return
// says so explicitly rather than reporting 0, because the confirmation screen
// shows "0% confidence" and "no confidence reported" as two very different
// warnings to a teacher, and conflating them would be a lie either way.
func aggregatePageConfidence(pages []visionPage) (float64, []string) {
	var sum float64
	var counted int
	for _, p := range pages {
		if p.Confidence == nil {
			continue
		}
		sum += *p.Confidence
		counted++
	}
	if counted == 0 {
		return 0, []string{"The engine did not report a confidence score for this page."}
	}
	avg := sum / float64(counted)
	if avg < 0.6 {
		return avg, []string{fmt.Sprintf(
			"Low engine confidence (%.0f%%) — check this page's reading against the photo before accepting it.",
			avg*100)}
	}
	return avg, nil
}
