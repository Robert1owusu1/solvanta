-- Independent teacher workspaces (Phase 3). A school is either a normal
-- `school` or an independent teacher's own `independent` workspace, owned by
-- one teacher and limited to a reduced feature set. All additive and
-- idempotent; existing rows default to `school`.

ALTER TABLE schools
    ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'school'
    CHECK (kind IN ('school','independent'));
ALTER TABLE schools
    ADD COLUMN IF NOT EXISTS owner_user_id TEXT;
ALTER TABLE schools
    ADD COLUMN IF NOT EXISTS data_protection_accepted_at TEXT;
ALTER TABLE schools
    ADD COLUMN IF NOT EXISTS archived BOOLEAN NOT NULL DEFAULT FALSE;
