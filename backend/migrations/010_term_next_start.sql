-- When school reopens for the next term, printed as "Next term begins" on
-- report cards (domain.SchoolTerm.NextStart).
ALTER TABLE school_terms ADD COLUMN IF NOT EXISTS next_start TEXT;
