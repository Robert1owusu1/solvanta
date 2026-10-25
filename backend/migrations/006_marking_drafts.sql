-- =============================================================================
-- PHASE 5: AI Marking — draft marks from the matching engine
-- =============================================================================
--
-- A draft is what the matching engine proposes for one student's paper
-- against one exact scheme version. Drafts never count as marks: the real
-- marks stay in submissions.teacher_marks, written only when a teacher
-- finalizes a draft (Phase 6).

CREATE TABLE IF NOT EXISTS marking_drafts (
    id              TEXT PRIMARY KEY,
    -- No ON DELETE: a scheme with drafts cannot be deleted, and editing its
    -- marks forks a new version, so a draft always points at the scheme it
    -- was actually marked against.
    scheme_id       TEXT NOT NULL REFERENCES marking_schemes(id),
    scheme_version  INT  NOT NULL,
    target_kind     TEXT NOT NULL CHECK (target_kind IN ('assessment','assignment')),
    -- submissions.id for an assessment, the assignment_submissions record id
    -- for an assignment: two homes, so no foreign key.
    submission_id   TEXT NOT NULL,
    student_id      TEXT NOT NULL REFERENCES students(id),
    class_id        TEXT NOT NULL,
    -- The teacher-confirmed reading the draft was made from, kept verbatim
    -- so a draft can always be traced back to what was read.
    source_text     TEXT NOT NULL,
    ocr_job_ids     JSONB NOT NULL DEFAULT '[]'::jsonb,
    unassigned      JSONB NOT NULL DEFAULT '[]'::jsonb,
    status          TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','finalized','discarded')),
    draft_total     NUMERIC(8,2) NOT NULL DEFAULT 0,
    max_total       NUMERIC(8,2) NOT NULL DEFAULT 0,
    needs_review    INT NOT NULL DEFAULT 0,
    created_by      TEXT NOT NULL REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Set only by an explicit teacher action (Phase 6).
    finalized_by    TEXT REFERENCES users(id),
    finalized_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_marking_drafts_submission ON marking_drafts(submission_id);
CREATE INDEX IF NOT EXISTS idx_marking_drafts_scheme ON marking_drafts(scheme_id);
CREATE INDEX IF NOT EXISTS idx_marking_drafts_student ON marking_drafts(student_id);

-- One row per scheme question: the per-question link from a student's answer
-- to scheme_question_id that Phase 1 called for. Phase 7's class report
-- groups on it ("which questions did the class struggle with").
CREATE TABLE IF NOT EXISTS marking_draft_answers (
    draft_id            TEXT NOT NULL REFERENCES marking_drafts(id) ON DELETE CASCADE,
    scheme_question_id  TEXT NOT NULL REFERENCES scheme_questions(id),
    question_number     INT NOT NULL,
    student_answer      TEXT NOT NULL DEFAULT '',
    working             JSONB NOT NULL DEFAULT '[]'::jsonb,
    draft_marks         NUMERIC(6,2) NOT NULL DEFAULT 0,
    total_marks         NUMERIC(6,2) NOT NULL,
    method              TEXT NOT NULL,
    matched_text        TEXT NOT NULL DEFAULT '',
    matched_answer_id   BIGINT,
    misconception_id    BIGINT,
    likely_cause        TEXT NOT NULL DEFAULT '',
    needs_review        BOOLEAN NOT NULL DEFAULT FALSE,
    reasons             JSONB NOT NULL DEFAULT '[]'::jsonb,
    steps               JSONB NOT NULL DEFAULT '[]'::jsonb,
    PRIMARY KEY (draft_id, scheme_question_id)
);
CREATE INDEX IF NOT EXISTS idx_draft_answers_question ON marking_draft_answers(scheme_question_id);

-- -----------------------------------------------------------------------------
-- Phase 4 follow-up: keep each OCR reading on the server, so a reading whose
-- response was lost on a bad connection can be fetched again rather than the
-- page re-photographed. Nullable: NULL for requests made before this column.
-- -----------------------------------------------------------------------------
ALTER TABLE question_gen_requests ADD COLUMN IF NOT EXISTS ocr_result JSONB;
