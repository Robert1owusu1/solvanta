package ocr

import (
	"bytes"
	"io"
	"net/http"
	"strings"
)

// httpStub stands in for the network so the two real providers can be
// exercised end to end — request construction, header placement, body
// encoding, reply parsing — without a key and without a packet leaving the
// machine.
//
// That distinction matters for the report: these tests prove the providers
// build the request Mathpix and Google document and parse the reply they
// document. They do NOT prove either service accepts our account's traffic,
// because no account exists yet.
type httpStub struct {
	status  int
	payload string
	err     error

	// req is the single request observed, and body is what was sent on it.
	req  *http.Request
	body []byte
}

func (s *httpStub) Do(req *http.Request) (*http.Response, error) {
	if req.Body != nil {
		b, _ := io.ReadAll(req.Body)
		_ = req.Body.Close()
		s.body = b
		req.Body = io.NopCloser(bytes.NewReader(b))
	}
	s.req = req

	if s.err != nil {
		return nil, s.err
	}
	status := s.status
	if status == 0 {
		status = http.StatusOK
	}
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(s.payload)),
		Header:     make(http.Header),
		Request:    req,
	}, nil
}

// stubWith builds a stub answering with the given JSON payload.
func stubWith(payload string) *httpStub {
	return &httpStub{status: http.StatusOK, payload: payload}
}
