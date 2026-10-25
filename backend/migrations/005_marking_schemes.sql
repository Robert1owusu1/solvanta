-- =============================================================================
-- PHASE 1: AI Marking — Marking Schemes & Scan Pages
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Validation function: sum of mark_breakdown steps must equal total_marks
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION validate_mark_breakdown(total_marks NUMERIC, breakdown JSONB)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (
        SELECT COALESCE(SUM((step->>'marks')::NUMERIC), 0)
        FROM jsonb_array_elements(breakdown) AS step
    ) = total_marks;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- -----------------------------------------------------------------------------
-- Marking Schemes — structured grading templates linked to assessment OR assignment
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marking_schemes (
    id                  TEXT PRIMARY KEY,
    assessment_id       TEXT REFERENCES assessments(id) ON DELETE SET NULL,
    assignment_id       TEXT REFERENCES assignments(id) ON DELETE SET NULL,
    version             INT NOT NULL DEFAULT 1,
    parent_scheme_id    TEXT REFERENCES marking_schemes(id) ON DELETE SET NULL,
    created_by          TEXT NOT NULL REFERENCES users(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Exactly one of assessment_id or assignment_id must be set
    CONSTRAINT chk_scheme_target CHECK (
        (assessment_id IS NOT NULL) != (assignment_id IS NOT NULL)
    )
);
CREATE INDEX IF NOT EXISTS idx_marking_schemes_assessment ON marking_schemes(assessment_id);
CREATE INDEX IF NOT EXISTS idx_marking_schemes_assignment ON marking_schemes(assignment_id);
CREATE INDEX IF NOT EXISTS idx_marking_schemes_parent ON marking_schemes(parent_scheme_id);

-- -----------------------------------------------------------------------------
-- Scheme Questions — each question in the scheme with mark breakdown
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scheme_questions (
    id                  TEXT PRIMARY KEY,
    scheme_id           TEXT NOT NULL REFERENCES marking_schemes(id) ON DELETE CASCADE,
    question_number     INT NOT NULL,
    total_marks         NUMERIC(6,2) NOT NULL,
    mark_breakdown      JSONB NOT NULL DEFAULT '[]'::jsonb,
    -- mark_breakdown: [{"id": "step-1", "type": "method", "criteria": "...", "marks": 2.0}, ...]
    -- Validation: sum(step.marks) == total_marks enforced by DB constraint
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (scheme_id, question_number),
    CONSTRAINT chk_mark_breakdown_sum CHECK (validate_mark_breakdown(total_marks, mark_breakdown))
);
CREATE INDEX IF NOT EXISTS idx_scheme_questions_scheme ON scheme_questions(scheme_id);

-- -----------------------------------------------------------------------------
-- Accepted Answer Variants — exact + normalized forms for fuzzy matching
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scheme_accepted_answers (
    id                      BIGSERIAL PRIMARY KEY,
    scheme_question_id      TEXT NOT NULL REFERENCES scheme_questions(id) ON DELETE CASCADE,
    answer_text             TEXT NOT NULL,                 -- teacher-entered exact text
    normalized_form         TEXT NOT NULL,                 -- lowercased, stripped whitespace/punctuation
    marks_awarded           NUMERIC(6,2) NOT NULL,         -- marks for this variant
    is_primary              BOOLEAN NOT NULL DEFAULT FALSE,-- one primary per question for display
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_accepted_answers_sq ON scheme_accepted_answers(scheme_question_id);
CREATE INDEX IF NOT EXISTS idx_accepted_answers_norm ON scheme_accepted_answers(normalized_form);

-- -----------------------------------------------------------------------------
-- Misconceptions — common wrong patterns with likely causes
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scheme_misconceptions (
    id                      BIGSERIAL PRIMARY KEY,
    scheme_question_id      TEXT NOT NULL REFERENCES scheme_questions(id) ON DELETE CASCADE,
    wrong_answer_pattern    TEXT NOT NULL,                 -- normalized wrong answer
    likely_cause            TEXT NOT NULL,                 -- e.g. "confused numerator/denominator"
    marks_awarded           NUMERIC(6,2) NOT NULL DEFAULT 0, -- partial credit if applicable
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_misconceptions_sq ON scheme_misconceptions(scheme_question_id);

-- -----------------------------------------------------------------------------
-- Submissions — add scheme link for audit/history (prevents silent re-grading)
-- -----------------------------------------------------------------------------
ALTER TABLE submissions 
    ADD COLUMN IF NOT EXISTS marking_scheme_id TEXT,
    ADD COLUMN IF NOT EXISTS marking_scheme_version INT;

-- Non-FK: scheme may be deleted but submission keeps the id for history
CREATE INDEX IF NOT EXISTS idx_submissions_scheme ON submissions(marking_scheme_id);

-- -----------------------------------------------------------------------------
-- Scan Pages — photographed pages linked to submission (for multi-page + OCR)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scan_pages (
    id                  TEXT PRIMARY KEY,
    submission_id       TEXT NOT NULL REFERENCES submissions(id) ON DELETE CASCADE,
    scheme_id           TEXT REFERENCES marking_schemes(id) ON DELETE SET NULL,
    page_number         INT NOT NULL,
    image_id            TEXT REFERENCES scan_images(id) ON DELETE SET NULL,
    ocr_text            TEXT,                          -- raw OCR output
    ocr_confidence      NUMERIC(5,4),                  -- average confidence 0-1
    ocr_status          TEXT NOT NULL DEFAULT 'pending' CHECK (ocr_status IN
        ('pending','processing','ready','needs_review','failed')),
    ocr_metadata        JSONB DEFAULT '{}'::jsonb,     -- engine, model, timings, etc.
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (submission_id, page_number)
);
CREATE INDEX IF NOT EXISTS idx_scan_pages_submission ON scan_pages(submission_id);
CREATE INDEX IF NOT EXISTS idx_scan_pages_scheme ON scan_pages(scheme_id);
CREATE INDEX IF NOT EXISTS idx_scan_pages_ocr_status ON scan_pages(ocr_status);