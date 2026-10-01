-- Fees & payments (client: lib/features/fees).
--
-- The cashier's device firm-commits a payment to its local store first and
-- replays it here through the sync outbox, so `id` is chosen BY THE CLIENT:
-- the insert is ON CONFLICT (id) DO NOTHING and a replayed payment writes
-- nothing the second time. Without that, a retried push would record the same
-- collection twice.
--
-- No FK on invoice_id on purpose: fees invoices are still a device-local
-- record, so this column is a cross-reference into that record rather than a
-- constraint against a table the backend does not own yet.
CREATE TABLE IF NOT EXISTS payments (
    id          TEXT PRIMARY KEY,
    invoice_id  TEXT NOT NULL,
    amount      INTEGER NOT NULL CHECK (amount > 0),
    -- cash | card | mobileMoney | bank, but deliberately NOT a CHECK: the
    -- client picks this from a Dart enum, and an enum value this server has
    -- never heard of must still record the money rather than be rejected —
    -- ApiClient drops a 4xx from the outbox, so a strict check here could
    -- lose a payment whenever the app gains a method before the API does.
    -- PaymentMethod.fromKey already renders anything unexpected as cash.
    method      TEXT NOT NULL,
    -- Momo ID, cash receipt number, bank trace; may be empty.
    reference   TEXT NOT NULL DEFAULT '',
    -- App-facing display string ("2026-10-01 09:41"), stored as-is like every
    -- other timestamp in this schema.
    paid_at     TEXT NOT NULL,
    recorded_by TEXT NOT NULL
);
