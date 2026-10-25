-- =============================================================================
-- PHASE 6: AI Marking — the teacher's final decision beside the proposal
-- =============================================================================
--
-- draft_marks is what the matching engine proposed and is never overwritten.
-- final_marks is what the teacher decided when finalizing (NULL until then),
-- and teacher_note says why when the two differ. Keeping both makes every
-- override visible to later reports and audits.

ALTER TABLE marking_draft_answers
    ADD COLUMN IF NOT EXISTS final_marks  NUMERIC(6,2),
    ADD COLUMN IF NOT EXISTS teacher_note TEXT NOT NULL DEFAULT '';
