-- Optional passport photo per pupil, shown on the ID card and report card.
-- Stored as a data URI (data:image/jpeg;base64,...) or an http(s) URL.
-- Additive and idempotent.
ALTER TABLE students ADD COLUMN IF NOT EXISTS photo_url TEXT;
