package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"solvanta/backend/internal/ocr"
	"solvanta/backend/internal/store"
)

// spyProvider is a recogniser that records what it was asked and returns a
// fixed reading. It exists so this phase's endpoint wiring can be PROVEN
// rather than assumed: if the handler ever stopped routing through the
// router, or stopped forwarding the photo, these tests fail.
type spyProvider struct {
	kind  ocr.Kind
	label string
	calls []ocr.Input
}

func (s *spyProvider) Kind() ocr.Kind { return s.kind }

func (s *spyProvider) Recognize(_ context.Context, in ocr.Input) (*ocr.Result, error) {
	s.calls = append(s.calls, in)
	// finish() is package-private in ocr, so the shared derived fields are
	// set explicitly here — exactly as a real provider's finish() would.
	return &ocr.Result{
		Text:       s.label,
		Confidence: 0.9,
		RequestID:  "spy-1",
		Provider:   s.kind,
		Lines:      3,
		CostTier:   ocr.TierStandard,
		Warnings:   []string{},
	}, nil
}

// newOCRServer returns the router and the Server, so a test can swap in spies.
func newOCRServer(t *testing.T) (*gin.Engine, *Server) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	s, err := NewServer(store.New(), Config{})
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return s.Router(), s
}

// newGenRequest creates a generation request and returns its id.
func newGenRequest(t *testing.T, r http.Handler, token, body string) string {
	t.Helper()
	rec := do(r, "POST", "/api/questions/ai/requests", body, bearer(token))
	if rec.Code != http.StatusCreated {
		t.Fatalf("create request: got %d %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil || resp.ID == "" {
		t.Fatalf("create request returned no id: %s", rec.Body.String())
	}
	return resp.ID
}

func bearer(token string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + token}
}

// TestGenerateRouteKeepsItsRoleMatrix locks the authorization on the endpoint
// this phase rewired. Changing a handler is exactly when route-level
// authorization is most likely to be lost by accident, so the matrix is
// asserted directly rather than trusted to be unchanged.
func TestGenerateRouteKeepsItsRoleMatrix(t *testing.T) {
	r := newTestServer(t, Config{})

	allowed := []string{"superAdmin", "schoolAdmin", "headteacher", "teacher"}
	denied := []string{"parent", "student"}

	// An anonymous caller must be stopped before the handler runs.
	anon := do(r, "POST", "/api/questions/ai/requests/QGEN-X/generate", ``, nil)
	if anon.Code != http.StatusUnauthorized {
		t.Errorf("unauthenticated generate = %d, want 401", anon.Code)
	}

	for _, role := range allowed {
		tok := login(t, r, demoAccounts[role][0], demoAccounts[role][1])
		id := newGenRequest(t, r, tok,
			`{"subjectId":"MATH","topic":"Algebra","type":"mcq","count":1}`)
		rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(tok))
		if rec.Code == http.StatusForbidden {
			t.Errorf("%s was forbidden on generate (%d) — an allowed role must not be 403", role, rec.Code)
		}
		if rec.Code != http.StatusOK {
			t.Errorf("%s generate = %d %s", role, rec.Code, rec.Body.String())
		}
	}
	for _, role := range denied {
		tok := login(t, r, demoAccounts[role][0], demoAccounts[role][1])
		rec := do(r, "POST", "/api/questions/ai/requests/QGEN-X/generate", ``, bearer(tok))
		if rec.Code != http.StatusForbidden {
			t.Errorf("%s generate = %d, want 403", role, rec.Code)
		}
	}
}

// TestGenerateRoutesBySubjectToTheChosenProvider is the central wiring proof:
// Maths content must reach the math-notation provider and everything else the
// plain-handwriting one, with the photo and subject passed through intact.
func TestGenerateRoutesBySubjectToTheChosenProvider(t *testing.T) {
	r, s := newOCRServer(t)
	mathSpy := &spyProvider{kind: ocr.KindMathpix, label: "MATH ROUTE WAS USED"}
	textSpy := &spyProvider{kind: ocr.KindVision, label: "TEXT ROUTE WAS USED"}
	s.ocrs = ocr.NewRouterWith(mathSpy, textSpy)

	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	photo := base64.StdEncoding.EncodeToString([]byte("pretend-this-is-a-jpeg"))

	// A maths request should reach the math-notation provider.
	mathID := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"math","count":1}`)
	rec := do(r, "POST", "/api/questions/ai/requests/"+mathID+"/generate",
		`{"imageBase64":"`+photo+`"}`, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("math generate: %d %s", rec.Code, rec.Body.String())
	}
	assertOCROnResponse(t, rec.Body.Bytes(), string(ocr.KindMathpix), "MATH ROUTE WAS USED")

	// A science request should reach the plain-text provider instead.
	sciID := newGenRequest(t, r, tok, `{"subjectId":"SCI","topic":"Cells","type":"shortAnswer","count":1}`)
	rec = do(r, "POST", "/api/questions/ai/requests/"+sciID+"/generate",
		`{"imageBase64":"`+photo+`"}`, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("science generate: %d %s", rec.Code, rec.Body.String())
	}
	assertOCROnResponse(t, rec.Body.Bytes(), string(ocr.KindVision), "TEXT ROUTE WAS USED")

	if len(mathSpy.calls) != 1 {
		t.Errorf("math provider was called %d times, want 1", len(mathSpy.calls))
	}
	if len(textSpy.calls) != 1 {
		t.Errorf("text provider was called %d times, want 1", len(textSpy.calls))
	}

	// The photo and subject must survive the trip: without the bytes the
	// recogniser would be reading nothing, and without the subject the
	// subject-level default could not be applied by anything downstream.
	for _, call := range mathSpy.calls {
		if call.SubjectID != "MATH" {
			t.Errorf("math call subjectId = %q, want MATH", call.SubjectID)
		}
		if len(call.Image) == 0 {
			t.Error("the photo never reached the recogniser")
		}
		if got, want := len(call.Image), len(mustDecode(t, photo)); got != want {
			t.Errorf("photo bytes = %d, want %d", got, want)
		}
	}
}

// TestGenerateQuestionLevelOverrideBeatsSubjectDefault covers the mixed-
// subject case: one equation-bearing question inside a plain-text subject has
// to be able to reach Mathpix, and a maths page to be sent to Vision.
func TestGenerateQuestionLevelOverrideBeatsSubjectDefault(t *testing.T) {
	r, s := newOCRServer(t)
	mathSpy := &spyProvider{kind: ocr.KindMathpix, label: "MATH ROUTE WAS USED"}
	textSpy := &spyProvider{kind: ocr.KindVision, label: "TEXT ROUTE WAS USED"}
	s.ocrs = ocr.NewRouterWith(mathSpy, textSpy)

	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])

	// Plain-text subject forced onto the math engine.
	id := newGenRequest(t, r, tok, `{"subjectId":"SCI","topic":"Forces","type":"math","count":1}`)
	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate",
		`{"ocrProvider":"mathpix"}`, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("override generate: %d %s", rec.Code, rec.Body.String())
	}
	assertOCROnResponse(t, rec.Body.Bytes(), string(ocr.KindMathpix), "MATH ROUTE WAS USED")
	if len(mathSpy.calls) != 1 || len(textSpy.calls) != 0 {
		t.Fatalf("calls = math %d, text %d; want 1 and 0", len(mathSpy.calls), len(textSpy.calls))
	}

	// A nonsense override must not decide anything for a student's page: it
	// falls back to the subject default rather than being honoured.
	id = newGenRequest(t, r, tok, `{"subjectId":"SCI","topic":"Forces","type":"math","count":1}`)
	rec = do(r, "POST", "/api/questions/ai/requests/"+id+"/generate",
		`{"ocrProvider":"telepathy"}`, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("bad override generate: %d %s", rec.Code, rec.Body.String())
	}
	assertOCROnResponse(t, rec.Body.Bytes(), string(ocr.KindVision), "TEXT ROUTE WAS USED")
}

// TestGenerateNeverReportsOutputAsConfirmed guards the rule this whole
// pipeline rests on: OCR output is never treated as accepted. It leaves the
// server unconfirmed every single time, because acceptance is a teacher's act
// taken at the confirmation screen — not something a flag can pre-decide.
func TestGenerateNeverReportsOutputAsConfirmed(t *testing.T) {
	r, s := newOCRServer(t)
	s.ocrs = ocr.NewRouterWith(
		&spyProvider{kind: ocr.KindMathpix, label: "m"},
		&spyProvider{kind: ocr.KindVision, label: "t"})

	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"math","count":1}`)
	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("generate: %d %s", rec.Code, rec.Body.String())
	}

	var resp struct {
		OCR struct {
			Confirmed bool `json:"confirmed"`
		} `json:"ocr"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.OCR.Confirmed {
		t.Fatal("the server reported OCR output as confirmed — no mark may be finalized this way")
	}
}

// TestGenerateKeepsTheClientContract proves the response stayed additive: the
// existing client decodes this straight into QuestionGenRequest, so every
// field it already reads must still be present at the TOP level while the new
// "ocr" block sits alongside it.
func TestGenerateKeepsTheClientContract(t *testing.T) {
	r, s := newOCRServer(t)
	s.ocrs = ocr.NewRouterWith(
		&spyProvider{kind: ocr.KindMathpix, label: "reading"},
		&spyProvider{kind: ocr.KindVision, label: "reading"})

	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"mcq","count":2}`)
	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("generate: %d %s", rec.Code, rec.Body.String())
	}

	var resp map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, field := range []string{"id", "status", "drafts", "subjectId", "topic", "ocr"} {
		if _, ok := resp[field]; !ok {
			t.Errorf("response is missing %q — the client reads it at the top level", field)
		}
	}
	// A nested shape would have silently emptied the client's model while
	// still parsing cleanly, so assert "request" is NOT the container.
	if _, nested := resp["request"]; nested {
		t.Error("request fields were nested under \"request\"; the client would decode empty")
	}
}

// TestGenerateDraftsCarryEngineProvenance: every draft must say which engine
// produced it and how sure it was, so none can be mistaken for one a human
// wrote.
func TestGenerateDraftsCarryEngineProvenance(t *testing.T) {
	r, s := newOCRServer(t)
	s.ocrs = ocr.NewRouterWith(
		&spyProvider{kind: ocr.KindMathpix, label: "recognised line one"},
		&spyProvider{kind: ocr.KindVision, label: "recognised line one"})

	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"mcq","count":2}`)
	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("generate: %d %s", rec.Code, rec.Body.String())
	}

	var resp struct {
		Drafts []struct {
			Stem        string `json:"stem"`
			Explanation string `json:"explanation"`
		} `json:"drafts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp.Drafts) != 2 {
		t.Fatalf("drafts = %d, want 2", len(resp.Drafts))
	}
	for _, d := range resp.Drafts {
		if !strings.Contains(d.Stem, "recognised line one") {
			t.Errorf("stem is not grounded in the recognised text: %q", d.Stem)
		}
		if !strings.Contains(d.Explanation, string(ocr.KindMathpix)) {
			t.Errorf("explanation does not name the engine: %q", d.Explanation)
		}
		if !strings.Contains(d.Explanation, "Review and edit before publishing") {
			t.Errorf("explanation does not require review: %q", d.Explanation)
		}
	}
}

// TestGenerateWithNoBodyStillWorks protects the path the shipping client
// already takes — it posts a null body when it asks the server to generate.
func TestGenerateWithNoBodyStillWorks(t *testing.T) {
	r, s := newOCRServer(t)
	// No router swap: this runs the real default (mock, since no keys exist).
	_ = s
	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"SCI","topic":"Cells","type":"mcq","count":1}`)

	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("generate with no body: %d %s", rec.Code, rec.Body.String())
	}
	assertOCROnResponse(t, rec.Body.Bytes(), string(ocr.KindMock), "")
	if got := s.OCRStatus(); !strings.Contains(got, "mock") {
		t.Errorf("startup status should say mock while no keys are set: %q", got)
	}
}

// TestGenerateWithNoKeysIsNotBlocked is the "runs fully without credentials"
// guarantee at the HTTP layer: no key means the mock answers, not a crash and
// not a call that hangs.
func TestGenerateWithNoKeysIsNotBlocked(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"math","count":1}`)

	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("generate without keys: %d %s", rec.Code, rec.Body.String())
	}
	assertOCROnResponse(t, rec.Body.Bytes(), string(ocr.KindMock), "MOCK OCR")
}

// TestGenerateRejectsMalformedImage: bad input stops at the door with a
// message naming the field, rather than reaching a provider as garbage.
func TestGenerateRejectsMalformedImage(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"math","count":1}`)

	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate",
		`{"imageBase64":"not base64!!"}`, bearer(tok))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("malformed image = %d, want 400", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "imageBase64") {
		t.Errorf("error should name the field: %s", rec.Body.String())
	}
}

// TestGenerateSkipsUnparsableBodyWhenAbsent: a request with a declared body
// that is not valid JSON is a 400, but a genuinely absent body is not treated
// as an error — the two must not be confused.
func TestGenerateSkipsUnparsableBodyWhenAbsent(t *testing.T) {
	r := newTestServer(t, Config{})
	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"math","count":1}`)

	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", `{{`, bearer(tok))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("garbage body = %d, want 400", rec.Code)
	}
}

// TestGenerateLogsTheRateItHit covers the cost-awareness requirement: the log
// must name the rate tier on every run, and call out explicitly when a page
// crossed the higher-rate threshold — built now so it is proven before any
// money is attached to it.
func TestGenerateLogsTheRateItHit(t *testing.T) {
	r, s := newOCRServer(t)

	// A provider that returns a long reading, pushing the page over the
	// threshold, so BOTH log lines can be asserted.
	long := strings.Repeat("a line of homework\n", 15)
	s.ocrs = ocr.NewRouterWith(
		&overLineProvider{kind: ocr.KindMathpix, text: long},
		&overLineProvider{kind: ocr.KindVision, text: long})

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"math","count":1}`)
	rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(tok))
	if rec.Code != http.StatusOK {
		t.Fatalf("generate: %d %s", rec.Code, rec.Body.String())
	}

	out := buf.String()
	if !strings.Contains(out, "ocr: cost") {
		t.Fatalf("no cost line was logged:\n%s", out)
	}
	if !strings.Contains(out, "rate="+string(ocr.TierHigh)) {
		t.Errorf("log does not name the rate tier:\n%s", out)
	}
	if !strings.Contains(out, "higher rate") {
		t.Errorf("crossing the threshold was not called out:\n%s", out)
	}
	if !strings.Contains(out, itoa(ocr.MathpixHighRateLines)+"-line threshold") {
		t.Errorf("log should state the threshold crossed:\n%s", out)
	}
}

// TestCostLogDoesNotNameTheStudent: the cost line goes to an application log,
// and a student's name in an application log is a student's name in a place
// nobody thought about.
func TestCostLogDoesNotNameTheStudent(t *testing.T) {
	r, s := newOCRServer(t)
	s.ocrs = ocr.NewRouterWith(
		&spyProvider{kind: ocr.KindMathpix, label: "x"},
		&spyProvider{kind: ocr.KindVision, label: "x"})

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	tok := login(t, r, demoAccounts["teacher"][0], demoAccounts["teacher"][1])
	id := newGenRequest(t, r, tok, `{"subjectId":"MATH","topic":"Algebra","type":"math","count":1}`)
	if rec := do(r, "POST", "/api/questions/ai/requests/"+id+"/generate", ``, bearer(tok)); rec.Code != http.StatusOK {
		t.Fatalf("generate: %d %s", rec.Code, rec.Body.String())
	}

	out := buf.String()
	for _, leak := range []string{"Kojo", "student123", "@school.gh"} {
		if strings.Contains(out, leak) {
			t.Errorf("cost log leaked %q:\n%s", leak, out)
		}
	}
}

// overLineProvider returns a reading long enough to cross the rate threshold.
type overLineProvider struct {
	kind ocr.Kind
	text string
}

func (o *overLineProvider) Kind() ocr.Kind { return o.kind }

func (o *overLineProvider) Recognize(_ context.Context, in ocr.Input) (*ocr.Result, error) {
	lines := 0
	for _, r := range strings.TrimRight(o.text, "\n") {
		if r == '\n' {
			lines++
		}
	}
	tier := ocr.TierStandard
	if lines > ocr.MathpixHighRateLines {
		tier = ocr.TierHigh
	}
	return &ocr.Result{
		Text: o.text, Provider: o.kind, Lines: lines, CostTier: tier,
		Confidence: 0.9, Warnings: []string{},
	}, nil
}

// assertOCROnResponse checks the OCR block on a generate response. A non-empty
// expected text additionally pins which provider served the call.
func assertOCROnResponse(t *testing.T, body []byte, wantProvider, wantText string) {
	t.Helper()
	var resp struct {
		OCR struct {
			Text       string     `json:"text"`
			Provider   ocr.Kind   `json:"provider"`
			CostTier   ocr.CostTier `json:"costTier"`
			Lines      int        `json:"lines"`
			Confidence float64    `json:"confidence"`
			Warnings   []string   `json:"warnings"`
			Confirmed  bool       `json:"confirmed"`
		} `json:"ocr"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode response: %v\n%s", err, body)
	}
	if resp.OCR.Provider != ocr.Kind(wantProvider) {
		t.Errorf("ocr.provider = %q, want %q", resp.OCR.Provider, wantProvider)
	}
	if wantText != "" && !strings.Contains(resp.OCR.Text, wantText) {
		t.Errorf("ocr.text = %q, want it to contain %q", resp.OCR.Text, wantText)
	}
	if resp.OCR.Confirmed {
		t.Error("ocr.confirmed must never be true straight from the server")
	}
	if resp.OCR.CostTier == "" {
		t.Error("ocr.costTier is empty; the rate must always be reported")
	}
	if resp.OCR.Warnings == nil {
		t.Error("ocr.warnings is null; clients ranging over it must not need a null check")
	}
}

func mustDecode(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return b
}
