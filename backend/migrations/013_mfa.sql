-- Two-factor authentication (TOTP). A per-user secret and an enabled flag;
-- both are server-only and never leave the API. Additive and idempotent.
ALTER TABLE users ADD COLUMN IF NOT EXISTS mfa_secret TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS mfa_enabled BOOLEAN NOT NULL DEFAULT FALSE;
