-- Fees: invoices (client: lib/features/fees, Invoice.toJson()).
--
-- The client keeps invoices in its own store today and never pushes them, so
-- this table exists to give the API a read side: a bursar on another device, a
-- parent portal, or a report can ask what was billed without depending on the
-- phone that raised it. The write side is idempotent on the client-chosen id
-- for the same reason payments are — an offline-first client may replay.
--
-- amount_paid and status are deliberately NOT columns. The client caches both
-- on the invoice, but a payment recorded on another device would immediately
-- make a stored copy wrong. The read side derives amountPaid by summing the
-- payments table and status from the same rule the app uses (paid / overdue /
-- partial / due), so every device agrees with the money rather than with a
-- snapshot taken when the invoice was written.
CREATE TABLE IF NOT EXISTS invoices (
    id          TEXT PRIMARY KEY,
    student_id  TEXT NOT NULL,
    -- 'yyyy-MM-dd'; DATE rather than TEXT so "what is overdue" can be asked
    -- in SQL later instead of shipped back for filtering.
    issue_date  DATE NOT NULL,
    due_date    DATE NOT NULL,
    -- "Term 1 · 2026/2027", stored exactly as the app renders it.
    term        TEXT NOT NULL DEFAULT '',
    -- [{name, amount}] as the client's FeeLineItem.toJson() writes it.
    line_items  JSONB NOT NULL DEFAULT '[]'
);

-- The student a payment belongs to, so a read can be scoped per student
-- without resolving its invoice first. Added after payments already existed,
-- hence ADD COLUMN IF NOT EXISTS and no NOT NULL: rows written before this
-- migration keep NULL and are visible only to staff reads.
--
-- Deliberately no FK, on both tables. A payment must never be rejected over
-- its index: the client may hold a student the server has not received yet,
-- and dropping the request would drop the money with it (ApiClient discards a
-- 4xx from the outbox). The same reasoning as invoice_id in 002.
ALTER TABLE payments ADD COLUMN IF NOT EXISTS student_id TEXT;

-- Backfill what is knowable: a payment whose invoice is already on the server
-- inherits that invoice's student. Payments whose invoice is still device-local
-- stay NULL, which is honest — the server does not know the student yet.
UPDATE payments p SET student_id = i.student_id
    FROM invoices i
    WHERE p.invoice_id = i.id AND p.student_id IS NULL;
