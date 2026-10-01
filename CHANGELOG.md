# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- PostgreSQL store chosen by `POSTGRES_DSN`, with schema in
  `backend/migrations` applied automatically at boot (all statements are
  `IF NOT EXISTS`).
- Stable development signing key: `run-dev.cmd`/`run-dev.ps1` generate a
  `SECRET` once and persist it in `.env`, so bearer tokens survive a backend
  restart instead of being invalidated on every boot.
- `run-dev.ps1 -Check` — parse the environment and report it (secrets redacted)
  without starting the server.
- Pool hardening: `SetMaxOpenConns(10)`, `SetMaxIdleConns(5)`,
  `SetConnMaxLifetime(30m)`, `SetConnMaxIdleTime(5m)`.
- Regression tests: on-device secret hashing, stored API token session
  recovery, gate check-in role gating, message/notification visibility
  scoping, a Postgres data-race guard, and auth-failure outbox handling.
- PostgreSQL integration tests are runnable against a real database by setting
  `TEST_POSTGRES_DSN`; the workflow (and the three ways a failure there
  misleads) is documented in `backend/README.md`.
- `GET /health` reports storage failures next to `"status": "ok"` as
  `storageErrors`, `lastStorageError` and `lastStorageErrorAt`.
- `Postgres.StoreErrors()` records every storage failure. The `Store` contract
  has no error channel — a failed `INSERT` was logged and then reported to the
  caller as success — so failures are now latched where the boot path, `/health`
  and the tests can ask about them.

### Performance

Every query against the remote pooler costs a round trip (~150 ms), so the
store's per-row loops dominated request latency. They now cost one round trip
per *collection*:

- `Assessments()` loaded each assessment's questions with its own query, making
  `GET /api/assessments` cost 1+N round trips and scale with the size of the
  school; `Assignments()` did the same for completion lists. Both are now a
  single query grouped by parent id.
- Multi-row writes are single statements built from a JSON array: user↔student
  links, assignment completions, student contacts (guardians, emergency
  contacts, authorized pickups), and both attendance writers. Seeding a term's
  attendance previously cost one round trip per student/day.
- `StudentByID` resolved one student's contacts by reading the **entire**
  contact table, so every gate check-in shipped every other student's
  guardians back across the pool. It now filters by student.

### Fixed

- **A gate arrival could appear twice.** The gate device records locally and
  pushes afterwards, but `POST /api/gate/events` discarded the client's `id`
  (the request struct had no such field) and minted a new one each time. A
  replayed push therefore stored a *second* record for one arrival, and
  `SafetyRepository` merges the local and server trails **by id** — so the
  safety log, and the pickup screen, showed the same arrival twice. The server
  now honours a client-supplied id, which also makes the POST idempotent via
  the existing `ON CONFLICT (id) DO NOTHING`. The in-memory store now mirrors
  that behaviour instead of appending unconditionally, so development matches
  production.
- **The seed drifted apart from the client and grew a little every day.**
  Gate events were keyed `GATE-<yesterday>-NNN` and the attendance window ended
  "yesterday", both taken from `time.Now()`. That is idempotent within a single
  calendar day — and no further: each boot on a new date wrote rows under brand
  new ids that collided with nothing, so the tables accumulated and the dataset
  slid forward while the client's copy stayed frozen where `LocalStore` first
  wrote it. "Local seed == remote store" could not hold for more than a day.
  The seed is now anchored to a fixed `seedRefDate`, so every boot emits
  byte-identical rows.
- `SaveDay` deleted the class/date bucket and then inserted replacement records
  one at a time; if an insert failed the error was only logged and the delete
  committed, leaving the day partly rewritten. It now aborts the transaction.
- **`SaveSubmission` silently dropped rows.** `toJSON` returns SQL NULL for an
  empty map while `submissions.answers` and `teacher_marks` are `NOT NULL`, so
  the seed's `SUB-M1-STU002` failed with SQLSTATE 23502 and was never written.
  The upsert now `COALESCE`s both columns to `{}`.
- **Expired sessions lost writes.** Only transport failures were queued in the
  offline outbox, so a 401/403 on a mutation was swallowed by callers: nothing
  queued, nothing retried, nothing surfaced, and the UI reported success.
  Mutations rejected with 401/403 are now enqueued on send and kept on replay
  (the real reason lands in `lastError`); `/auth/*` payloads are still never
  queued, and permanent 4xx rejections are still dropped so the outbox cannot
  be poisoned.
- A data race in the in-memory store: `deleteByID`/`removeMatch` filtered the
  store's own backing array in place while readers held an alias.
- Check-in role gating: the gate check-in no longer falls back to a permissive
  default role when the user object is incomplete, and scan mode is only
  offered to school staff.
- Global search and message repositories scope results to the signed-in user.
- PIN/passwords and other secrets are hashed at rest instead of stored in
  clear.
- **`TestTamperedAndExpiredTokens` failed about one run in six.** It "tampered"
  with the *last* character of the token, but when that character happened to
  be `w` the replacement `x` decoded to a byte-identical signature, so the
  request succeeded and the security assertion quietly passed for the wrong
  reason (measured: 6 failures in 100 runs; the trailing character is `w` in
  exactly 1 of 16 tokens). It now overwrites a middle signature character,
  separately proves a non-canonical twin is rejected, and checks the untouched
  token still works — so a broken login can no longer masquerade as a pass.

### Security

- **Bearer tokens are no longer malleable.** `parseToken` decoded the signature
  with Go's raw base64url decoder, which ignores the trailing bits a 32-byte
  HMAC does not use: the final character of a signature could be any of four
  characters (`w`, `x`, `y`, `z`) and still decode to the same MAC. One session
  could therefore authenticate under many different bearer strings. Both token
  segments are now re-encoded and compared against the original text, so a
  token is canonical — exactly one string per session. Not exploitable on its
  own (the decoded MAC is unchanged and revocation is keyed by `jti`), but
  anything that compares tokens as text would have seen strings never issued.
- Added `LICENSE` (MIT), `SECURITY.md`, and Dependabot configuration for the
  `pub`, `gomod`, `github-actions` and `docker` ecosystems.
- iOS `Info.plist` now declares `NSCameraUsageDescription`,
  `NSPhotoLibraryUsageDescription` and `NSFaceIDUsageDescription` — without
  them iOS terminates the app when the QR scanner, image picker or biometric
  lock is opened.

## [0.1.0] - 2026-01-01

Baseline: offline-first Flutter client, Go/Gin API with an in-memory store
seeded to match the client, RBAC across five roles, assessment and marking
flows, gate safety, messaging, reports/PDF, fees, offline sync queue and
app lock.
