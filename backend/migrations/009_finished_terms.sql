-- Terms a school has moved on from (domain.FinishedTerm), each with the
-- grading set-up in force when it ended, so transcripts and the year chart
-- read old results the way they were awarded, on every device.
CREATE TABLE IF NOT EXISTS finished_terms (
    school_id   TEXT NOT NULL,
    start_date  TEXT NOT NULL,
    data        JSONB NOT NULL,
    PRIMARY KEY (school_id, start_date)
);
