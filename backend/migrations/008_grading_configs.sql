-- Each school's grading set-up (domain.GradingConfig): its schemes, the
-- classes each covers, the class-score / exam split and the grade bands.
-- Stored whole as JSON — it is read and replaced as one document.
CREATE TABLE IF NOT EXISTS grading_configs (
    school_id   TEXT PRIMARY KEY,
    data        JSONB NOT NULL,
    updated_at  TEXT NOT NULL
);
