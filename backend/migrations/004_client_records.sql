-- Collections the client keeps for screens with no modelled table (timetable
-- slots, resources, safety-training completions, corrections, study targets,
-- scan pages). `data` is the client's own JSON for the row; student_id,
-- class_id and owner_id are lifted out of it so reads can be scoped without
-- unpacking every document.
CREATE TABLE IF NOT EXISTS client_records (
    kind        TEXT NOT NULL,
    id          TEXT NOT NULL,
    student_id  TEXT,
    class_id    TEXT,
    owner_id    TEXT,
    updated_at  TEXT NOT NULL,
    data        JSONB NOT NULL,
    PRIMARY KEY (kind, id)
);
CREATE INDEX IF NOT EXISTS idx_client_records_student ON client_records(kind, student_id);

-- The photo behind a scan page, uploaded separately from its record so a
-- record listing never ships megabytes of image data.
CREATE TABLE IF NOT EXISTS scan_images (
    id            TEXT PRIMARY KEY,
    content_type  TEXT NOT NULL,
    data          BYTEA NOT NULL
);

-- Read state per reader for notifications addressed to no single user: a
-- student-scoped notice reaches every parent of that student, and one parent
-- opening it must not clear it for the other.
CREATE TABLE IF NOT EXISTS notification_reads (
    notification_id  TEXT NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
    user_id          TEXT NOT NULL,
    PRIMARY KEY (notification_id, user_id)
);

-- Delivery receipts the recipient's device reports back.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS delivered_at TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS read_at TEXT;
