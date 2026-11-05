-- Optional emergency medical record per pupil (blood group, allergies,
-- conditions, medications, immunizations, notes). Additive and idempotent.
ALTER TABLE students ADD COLUMN IF NOT EXISTS health JSONB;
