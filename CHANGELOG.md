# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- New navigation. On large screens (1000px and up) a navy sidebar lists
  every module, grouped (People, Attendance & Safety, Teaching & Learning,
  Marking & Insights, Reports & Records, Communication, Finance), and the
  chosen module loads beside it under a white top bar with search,
  notifications and an account menu. The sidebar collapses to icons
  (remembered per person) and its search is focused with Ctrl/⌘+K. On phones
  and small tablets the same menu is a hamburger drawer. Home shows the
  overview and the modules opened most recently ("Jump back in") instead of
  a long grid of cards.
- AI marking, Phases 1–5: structured marking schemes with versioning,
  multi-page assignment capture with blur and lighting checks, an OCR pipeline
  (Mathpix / Cloud Vision / mock) with teacher confirmation, and a matching
  engine that drafts marks with a reason for each and flags anything
  uncertain. Drafts are stored apart from real marks (migration
  `006_marking_drafts.sql`) and are never final.
- AI marking Phase 6: a teacher review screen (Marking Dashboard → AI Marking
  Review) showing what was read, the proposed mark and why, per question.
  "Accept confident" fills in the confident marks; flagged questions must be
  ticked as checked or changed; finalizing is an explicit, confirmed action
  that records the marks and tells the parent. A "Draft marks" screen asks
  for a draft from confirmed readings or typed answers.
- AI marking Phase 7: feedback reports from finalized marks only. A
  per-student report lists the questions that lost marks, the likely
  misconception where the scheme names one, and a suggested next step
  (Marking Feedback for teachers and leaders, from Reports & Export, and a
  "Marking feedback" button on the Results screens parents and students
  already have). A per-class report
  shows how the class did on each question, which ones it struggled with,
  and who to go over them with. The last copy of each report is kept on the
  device, per account, for use offline.
- OCR readings are kept on the server for the teacher who asked for them,
  so a reading lost on a bad connection is fetched again rather than re-read.
- `docs/DEPLOYMENT.md`, `deploy/production.env.example`, `scripts/check.sh`
  and `scripts/build-web.sh` for deploying the web version first.
- `TRUSTED_PROXIES` for running the API behind a host's proxy.

### Fixed

- Dark mode: text and icons coloured with the fixed brand navy were nearly
  invisible on dark backgrounds; they now use the theme-aware brand colour
  (pale navy in dark mode) across 30 screens.
- Attendance: once every student in a class is marked for the day, the roll
  opens as taken and read-only instead of a fresh roll. "Edit attendance"
  unlocks it; saving a change asks for a reason and writes it to the audit
  log, and the roll locks again.
- Students and parents could read marking schemes (the answer key).
- On PostgreSQL a submission lost its marking-scheme link, so editing a
  scheme after marking rewrote it in place instead of versioning it.
- A pupil resubmitting a paper wiped the teacher's marks.
- Teachers could capture and mark work for classes other than their own.
- A classroom sharing one IP was locked out after ten sign-ins a minute,
  even correct ones.
- The OCR endpoint refused real-sized photos (over 1 MB).
- The scheme editor saved misconception patterns with their symbols
  stripped ("4/10" as "410"); new and re-saved schemes keep them as typed.

- The timetable, resources, safety-training completions, corrections, study
  targets and scan pages now reach the server (`/api/records/:kind`, migration
  `004_client_records.sql`) and follow each user to their other devices. Scan
  photos upload to `PUT /api/scans/:id/image` (up to 8 MB) and can be viewed
  from Capture on any staff device; a photo taken offline uploads later.
- Message delivery receipts travel to the sender (`POST
  /api/messages/:id/receipt`).
- Administrators can reset a forgotten password from Staff & Teachers or
  Parent linking (`POST /api/users/:id/reset-password`); the account is signed
  out everywhere. Editing an account's password now reaches the server too.
- A pupil un-ticking an assignment is synced (`DELETE
  /api/assignments/:id/complete`).
- Study targets are kept per user instead of per device.

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
- `POST /api/payments` — the fees module's missing write endpoint. The
  cashier's device firm-commits a payment to its local store and keeps
  replaying `payment.record` at `/api/payments`, but no such route existed, so
  every one of those pushes landed on `404`; `ApiClient` treats a 4xx as a
  permanent rejection and drops it from the outbox, leaving the collected cash
  on one device and in no record the school owns. The handler validates
  `invoiceId` and `amount`, then writes through an idempotent `SavePayment` —
  the client chooses the id and the insert is `ON CONFLICT (id) DO NOTHING`, so
  a retried push is answered `201` without the money being recorded twice —
  behind `IsSchoolStaff()`, the same five roles the client's fees screens gate
  the "Record payment" affordance on. Tests cover replay, validation, role
  gating and a failed write.
- The migration runner embeds every `backend/migrations/*.sql` in filename
  order instead of one hard-coded file, so a numbered migration is applied at
  boot rather than silently ignored.
- The fees module gained a read side: an `invoices` table behind
  `GET /api/invoices`, `GET /api/invoices/:id` and `POST /api/invoices`, plus
  `GET /api/payments?studentId=&invoiceId=` and a `student_id` column on
  payments. Fees were previously readable only on the device that raised them,
  so a bursar on a second device, a parent portal or any report could not ask
  what was billed or what had been paid. Invoice `amountPaid` and `status` are
  deliberately **not stored**: they are derived on every read by summing the
  payments table and resolving the client's own rule (paid / overdue / partial
  / due), because a copy written when the bill was raised would be right only
  until the next payment — which may arrive from another device. `student_id`
  is nullable and carries no FK on purpose: a payment must never be rejected
  over its index, as `ApiClient` drops a 4xx from the outbox and the money
  would go with it. Reads apply one rule — staff see every student, a parent
  their own children, a student themselves — and a student outside the
  caller's scope yields an empty list rather than an error naming them. The
  seed now raises the same one-invoice-per-term bill the app's `_buildSeed`
  does, so both sides describe the same fees.
- The Flutter client builds and runs in a browser (`flutter build web`).
  Generated files — fee PDFs, report cards, report exports, QR badges — go
  through one `saveAndShareFile()` helper: the share sheet on devices, a
  download on web, where there is no temp directory. On web the API endpoint
  comes only from `--dart-define=SOLVANTA_API` (`Platform.environment` throws in
  the browser), the lock screen skips `local_auth` (no web implementation) and
  goes to the PIN, and scan capture previews the photo from memory because
  `Image.file` cannot load image_picker's blob URL. The web client's origin must
  be listed in `ALLOWED_ORIGINS`; `backend/.env.example` shows the value.
  Known gap: a scan page captured on web stores only that blob URL as its
  `imagePath`, which dies with the tab — web scans need the bytes persisted or
  uploaded before the page can be processed later.

- **Every module syncs with the backend.** With `--dart-define=SOLVANTA_API`
  set, only sign-in and gate events used to reach the server, so attendance,
  marks, announcements, messages and fees entered on one device never showed
  on another. `ServerSync` now pulls each collection into the offline store
  (at sign-in, startup, resume, reconnect and every two minutes, never over
  unsent outbox writes) and every repository mirrors its writes, queued while
  offline. New API routes support it: `GET /api/attendance`,
  `/api/submissions`, `/api/notifications`; `PATCH /api/users/:id`;
  `PUT`/`DELETE /api/school/classes/:id`; `PUT /api/assessments/:id`;
  `DELETE /api/announcements/:id` and `/api/assignments/:id`.
  `test/server_sync_live_test.dart` checks four cross-device flows live.
- Responsive layouts for tablet and desktop widths (students, assessments,
  analytics, login, dashboard), and `test/screen_smoke_test.dart`, which opens
  every role's dashboard and modules at six widths and fails on any layout
  error.
- A support-staff demo account (`staff@school.gh` / `staff123`) and three
  seeded announcements, on both the app and the API.

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

- A student-scoped notification read by one parent no longer shows as read
  for the child's other guardians.

- **A failed write was reported to the client as success.** `Store` methods
  returned nothing, so every handler discarded the outcome: when the connection
  to Supabase dropped mid-request the API logged the error, answered `200`/`201`
  and the row simply never existed — a gate arrival, a student's contacts, an
  announcement or a marked paper that the app then displayed as saved. The 21
  payload-writing methods now return `error`, and every call site maps a failure
  to `500` with a generic message, so a client can retry instead of moving on;
  the SQL stays in the log and on `/health`, never in the response.
  `AddAudit` and `AddNotification` deliberately stay best-effort: they are
  incurred *after* the primary write, so failing the parent there would make
  clients replay requests that already succeeded and duplicate the announcement
  or message. `store.SaveStudent` contacts ride the same transaction as the
  student row, so a failing contact kind rolls the whole save back rather than
  committing a student whose guardians were dropped. Covered by tests that
  inject a failing store and assert `500` (and no SQL leak) instead of `201`.
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

- Responsive screens crashed at most widths (every laptop browser and phones
  in landscape): `ResponsiveBuilder` threw for device classes it had no
  builder for, and the desktop class was unreachable. The dashboard module
  grid also never rendered (unbounded height inside a list).
- Phone overflows: long subject names in dropdowns, the ID-card footer and
  report-card subject rows.
- A parent with children in two classes only saw the first child's class
  work; parents now get notices for new absences, late arrivals and
  completed assignments from the server.
- Deleting a class is refused while it still has students.
- Self sign-up is hidden against a backend, where it created an account that
  could never sync.

### Security

- New staff accounts no longer get a hidden `pass1234` default password;
  the form requires one that meets the API's password policy.
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
