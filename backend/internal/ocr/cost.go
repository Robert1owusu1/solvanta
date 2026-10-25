package ocr

import "log"

// LogCost writes the rate line for a page that has just been recognised.
//
// This runs on every recogniser call, keys or no keys, so the logging is
// exercised and proven by the test suite from day one rather than first
// being written once real money is attached to it. Mathpix bills at a higher
// per-page rate above [MathpixHighRateLines] lines, and the failure mode this
// exists to prevent is a term's worth of quietly over-billed pages nobody
// noticed until the invoice arrived.
//
// The line carries the page id, never anything about the student: it goes to
// an application log, and a name in an application log is a name in a place
// nobody thought about.
func LogCost(pageID string, res *Result) {
	if res == nil {
		return
	}
	if pageID == "" {
		pageID = "unidentified"
	}
	log.Printf("ocr: cost page=%s provider=%s lines=%d rate=%s duration_ms=%d",
		pageID, res.Provider, res.Lines, res.CostTier, res.DurationMS)
	if res.CostTier == TierHigh {
		// Called out separately so it can be grepped: this is the only line
		// that answers "did we cross the threshold, and how far over?"
		log.Printf("ocr: cost page=%s hit mathpix's higher rate: %d lines is above the %d-line threshold",
			pageID, res.Lines, MathpixHighRateLines)
	}
}
