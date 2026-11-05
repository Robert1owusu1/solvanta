-- Tamper-evident audit log: each entry carries a hash chaining it to the
-- previous one (domain.AuditChainHash). Additive and idempotent.
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS hash TEXT;
