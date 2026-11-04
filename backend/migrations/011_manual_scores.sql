-- Manual score entry (schools that mark on paper) and the per-school marking
-- mode that governs it. All additive and idempotent so the file is safe to
-- record on a database that already has the columns.

-- How a school records scores: 'ai', 'manual' or 'both'. NULL is read as the
-- default (both) by the application, so existing schools keep both paths open.
ALTER TABLE schools
    ADD COLUMN IF NOT EXISTS marking_mode TEXT
    CHECK (marking_mode IS NULL OR marking_mode IN ('ai','manual','both'));

-- A "score-only" assessment carries an explicit maximum and no questions. NULL
-- means "derive the total from the questions", the historical behaviour.
ALTER TABLE assessments
    ADD COLUMN IF NOT EXISTS max_score DOUBLE PRECISION;

-- Where a submission's score came from, an optional per-score remark, and
-- whether the pupil was absent (not the same as a zero, and excluded from
-- averages). source NULL is read as 'online', the historical default.
ALTER TABLE submissions
    ADD COLUMN IF NOT EXISTS source TEXT
    CHECK (source IS NULL OR source IN ('ai','manual','online'));
ALTER TABLE submissions
    ADD COLUMN IF NOT EXISTS remark TEXT;
ALTER TABLE submissions
    ADD COLUMN IF NOT EXISTS absent BOOLEAN NOT NULL DEFAULT FALSE;
