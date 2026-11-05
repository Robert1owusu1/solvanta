# Operations: backups, recovery, sync and observability

Practical runbook for running SOLVANTA in production. Pair it with
`docs/DEPLOYMENT.md` (how to deploy) and `backend/README.md` (env vars).

## Backups & disaster recovery

SOLVANTA is multi-tenant: one PostgreSQL **schema per school**
(`school_<id>`), plus the shared **`public`** schema (the tenant registry and
the sign-in directory). A complete backup must include all of them.

### What to back up

- Every `school_*` schema (the schools' data).
- The `public` schema (`public.tenants`, `public.user_directory`).

A whole-database dump covers all of this in one file:

```sh
# Full logical backup (all schemas), compressed.
pg_dump --format=custom --no-owner "$POSTGRES_DSN" > solvanta-$(date +%F).dump
```

For a single school (e.g. to export or move one tenant):

```sh
pg_dump --format=custom --schema="school_sch_001" "$POSTGRES_DSN" > sch-001.dump
```

### Restore

```sh
# Whole database into a fresh target.
pg_restore --no-owner --clean --if-exists --dbname "$TARGET_DSN" solvanta-YYYY-MM-DD.dump
```

### Schedule & retention (recommended)

- **Daily** automated `pg_dump` to off-host storage; keep 30 days.
- **Weekly** copy retained for 3 months.
- **Point-in-time recovery**: enable WAL archiving on the PostgreSQL server (or
  use your managed provider's PITR) so you can recover to any moment, not just
  the last nightly dump.
- **Test restores quarterly** into a scratch database — an untested backup is
  not a backup.

### Super-admin export (app-level)

Independent of the database, a super admin can export one school's data as JSON
(`GET /api/schools/:id/export`), and any user can export their own personal data
(`GET /api/me/export`). These are convenience/DSAR exports, not a substitute for
database backups.

## Offline-first sync & conflict strategy

The client is offline-first: every write is committed locally first, then
mirrored to the server (directly when online, or replayed from the sync outbox
when connectivity returns). The server is the source of truth once configured.

The write model avoids most conflicts by construction:

- **Client-chosen idempotent ids.** The device names its own records (payments,
  submissions, gate events, …). Replaying the same write is a no-op on the
  server (`ON CONFLICT (id) DO NOTHING` / upsert), so a retried outbox entry
  never double-applies — e.g. a payment is never recorded twice.
- **Last-writer-wins on mutable rows.** For records that are edited rather than
  appended (an invoice's terms, a student profile, a manual score), a save
  upserts on the id: the most recent write wins. This is intentional and is why
  edits carry an audit entry (old → new) so a human can see what changed.
- **Append-only trails never overwrite.** Gate events and payments accumulate;
  they are added, not replaced, so two devices recording different events both
  land. Attendance is replaced per `(class, date)` as one unit, never merged
  field-by-field.
- **Protected transitions are server-enforced.** Some writes are refused rather
  than merged: a pupil cannot overwrite a paper already marked (409), a manual
  score in a finished term is locked, and an AI-marked score needs an explicit
  override. These guards live on the API so offline replay cannot bypass them.

Operational implication: when the same mutable row is edited on two devices
while offline, the later sync wins and the earlier edit is overwritten. The
audit log records both writes. There is no automatic field-level merge; if that
is ever needed for a specific record type, add a version/`updatedAt` check on
that type's save path.

## Observability

- **`GET /health`** — liveness; also reports storage errors alongside
  `"status":"ok"` (it stays `ok` so the client keeps syncing).
- **`GET /metrics`** — Prometheus metrics (request counts by status, total
  request duration, uptime). Set `METRICS_TOKEN` to require a bearer token when
  the scrape endpoint is reachable from outside; scrape it from Prometheus and
  alert on 5xx rate and latency.
- **Structured logs** — one line per request
  (`level=info ts=… method=… path=… status=… latency=… ip=…`), ready for a log
  shipper (Loki, CloudWatch, …).

## Security operations

- Rotate `SECRET` only during a maintenance window — it invalidates all live
  sessions (every bearer token).
- Keep `METRICS_TOKEN`, SMTP and SMS credentials in a secrets manager, never in
  the repo.
- The **audit log is tamper-evident** (hash-chained): run
  `GET /api/audit/verify` periodically; a `valid:false` result means an entry
  was altered or dropped at `brokenAt`.
- Encourage (or require) **two-factor** for admin accounts (Settings → Account
  security).
```
