# SOLVANTA Backend

Production-oriented Go API for the SOLVANTA education platform, built to match
the **current state of the Flutter client** — same camelCase JSON contracts,
same enum string keys, same marking & analytics math. Feature mapping to the
project documentation is noted against each route/section (doc §…).

## Stack (per doc §52–54)

- **API:** Go + Gin
- **Storage:** PostgreSQL (schema applied automatically from
  `migrations/001_init.sql`); an in-memory store is used for development and
  kept in parity with the app seed. `POSTGRES_DSN` switches between them with
  the same `Store` interface as the seam.
- **Auth:** HMAC-signed bearer tokens (`base64url(claims).base64url(hmac)` with
  `sub/exp/iat/jti` claims), role + tenant middleware with token-revocation
  blacklist. Passwords are **bcrypt-hashed** (seeded at low cost for demo speed;
  runtime hashing uses the default cost); no plaintext passwords anywhere.
- **AI:** `POST /api/questions/ai/...` simulates the Python pipeline
  (FastAPI/Transformers per §54); drafts are templated locally
- **Marking:** mirrors the app's `computeEarned`, `gradeLetter`, blueprint pick,
  gap analytics, weak-topic analysis (§17–18, §26–32)

## Run

Requires Go ≥ 1.22. From this directory:

```sh
# development (in-memory store, seeded with demo data)
go run ./cmd/server

# customise
PORT=8080 SECRET=my-secret go run ./cmd/server

# tests — the PostgreSQL integration tests SKIP unless TEST_POSTGRES_DSN is set
go test ./...
go vet ./...
```

### PostgreSQL integration tests

`internal/store/postgres_test.go` needs a **disposable** database: each test
truncates every table in `public` before it runs. Give it its own database, never
the one the server is serving from:

```sh
# 1. create an empty database (once)
psql "$POSTGRES_DSN" -c 'CREATE DATABASE solvanta_test'

# 2. point the suite at it and run
TEST_POSTGRES_DSN='postgres://…@aws-0-eu-west-2.pooler.supabase.com:5432/solvanta_test?sslmode=require' \
  go test ./internal/store/ -count=1
```

Both DSNs belong in `.env`, which `run-dev.*` exports to the server process:

```dotenv
POSTGRES_DSN=postgres://…/postgres?sslmode=require
TEST_POSTGRES_DSN=postgres://…/solvanta_test?sslmode=require
```

Unset `TEST_POSTGRES_DSN` and the suite skips — that is why `go test ./...`
stays green on a machine with no database.

Three properties worth knowing before reading a failure:

- **The tests are slow by design.** Each query is a round trip to a remote
  pooler (~150 ms), so a full run takes minutes. `NewPostgres` runs the
  migrations and the test's own setup, not just the assertions.
- **A failure can be an outage, not a bug.** The store has no error channel, so
  a dropped connection mid-test shows up as an assertion mismatch 100+ seconds
  in rather than as a connection error. The suite now records storage failures
  and reports them alongside the assertion (`N storage operation(s) failed and
  were only logged`), which tells the two apart.
- **It is not safe to run twice concurrently** — the tests share one database.

### Windows

PowerShell's default execution policy refuses to load `.ps1` files, so go
through the `.cmd` wrapper:

```bat
run-dev.cmd -Check    &rem read .env, report what it parsed, do not start
run-dev.cmd           &rem run on :8080
```

`run-dev.ps1` loads the dotenv file `.env` (an optional PowerShell override,
`.env.ps1`, is applied on top). Copy `.env.example` → `.env` first.

### Supabase

Paste the **Session pooler** connection string from
*Dashboard → Project Settings → Database* into `.env`:

```dotenv
POSTGRES_DSN=postgres://postgres.<REF>:<PASSWORD>@aws-0-<REGION>.pooler.supabase.com:5432/postgres?sslmode=require
TEST_POSTGRES_DSN=postgres://postgres.<REF>:<PASSWORD>@aws-0-<REGION>.pooler.supabase.com:5432/solvanta_test?sslmode=require
```

* Host **`aws-0-<REGION>.pooler.supabase.com`**, not `db.<REF>.supabase.co`.
  The direct hostname resolves to AAAA only on some resolvers, and on a machine
  with no global IPv6 address `getaddrinfo` fails it outright with "no such
  host" — which looks like a DNS outage but is really an address-family one.
* Port **5432** selects the pooler's **Session** mode, **6543** its
  **Transaction** mode. Use Session: pgx prepares statements by default, and
  Transaction mode cannot keep a prepared statement alive across calls, so the
  first query fails with a "prepared statement" error. Session mode also
  permits `CREATE DATABASE`, which the test database needs.
* `sslmode=require` is mandatory; the pooler refuses `sslmode=disable`.
* The schema in `migrations/` is applied automatically at boot and every
  statement is `IF NOT EXISTS`, so pointing at an existing database is safe.
* The round trip to the pooler (~150 ms) dominates latency, so the store
  batches what it can: questions and completion lists load one query per
  *collection* rather than one per row, and multi-row writes (student contacts,
  user↔student links, attendance) go in as a single statement. Adding a
  per-row query inside a request handler is the easy way to add seconds.
* `SEED` stays off in production unless explicitly set, so seeding cannot
  silently grow a super-admin on a real database.

### Production

```sh
export POSTGRES_DSN="postgres://…?sslmode=require"   # see above
ENV=production SECRET=$(openssl rand -hex 32) PORT=8080 go run ./cmd/server

# skip the demo dataset on an existing production database
POSTGRES_DSN="$POSTGRES_DSN" SEED=false go run ./cmd/server
```

Environment variables:

| Var               | Default | Purpose                                              |
|-------------------|---------|------------------------------------------------------|
| `ADDR`            | `:8080` | Listen address (overrides `PORT`)                    |
| `PORT`            | `8080`  | Listen port                                          |
| `SECRET`          | random  | Token-signing key. **Required** when `ENV=production`|
| `ALLOWED_ORIGINS` | (none)  | Comma-separated CORS allow-list (e.g. web dashboard) |
| `ENV`             | dev     | Set `production` to enforce `SECRET` + HSTS          |
| `POSTGRES_DSN`    | (none)  | Enable PostgreSQL storage; schema is applied at boot |
| `SEED`            | `true`  | Seed the demo dataset on boot (`false` to skip)      |

> Storage uses the `Store` interface as its seam: `store.New()` is the in-memory
> in-process store (default), `store.NewPostgres(dsn, seed)` talks to PostgreSQL
> and applies the embedded `migrations/001_init.sql`. Both return exactly the
> same camelCase domain objects, so no HTTP-layer code changes when switching.
> The boot-time seed is idempotent (upserts + `ON CONFLICT DO NOTHING`), safe to
> re-run against an already-seeded database. Its dates are anchored to a fixed
> `seedRefDate` rather than `time.Now()`: relative dates made it idempotent only
> within one calendar day, so each boot on a new date inserted a fresh set of
> gate events and a shifted attendance window that never collided with the
> previous day's — the tables grew daily and drifted away from the client's
> seed, which `LocalStore` computes once at first launch and then freezes.
>
> `GET /health` reports storage trouble alongside `"status": "ok"`. It stays `ok`
> deliberately: the client reads that field to decide whether the server is
> *reachable*, and reporting storage errors as "down" would push the app into
> offline-only mode exactly when it should be syncing. When the Postgres store
> has recorded a failure the body also carries `storageErrors`,
> `lastStorageError` and `lastStorageErrorAt`. A failure during the boot-time
> seed aborts startup instead of serving an empty application.

## Demo logins

| Role        | Email                  | Password    |
|-------------|------------------------|-------------|
| Super admin | super@solvanta.app     | super123    |
| Admin       | admin@solvanta.app     | admin123    |
| Headteacher | head@school.gh         | head123     |
| Teacher     | efua.mensah@school.gh  | teacher123  |
| Parent      | ama.owusu@school.gh    | parent123   |
| Student     | kojo.owusu@school.gh   | student123  |

Every student also has a linked parent account — `USR-PRN-002` (akua.boaduwaa@school.gh)
through `USR-PRN-008` (ama.amponsah@school.gh), all `parent123` — so gate
arrival/departure/pickup notices resolve for the whole school.

## Authentication

```sh
TOKEN=$(curl -s -X POST localhost:8080/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"efua.mensah@school.gh","password":"teacher123"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

curl -H "Authorization: Bearer $TOKEN" localhost:8080/api/school
```

## Security

- **Passwords:** bcrypt at `DefaultCost`; seeded demo users use `MinCost` only
  to keep seeding fast (still verified with `bcrypt.CompareHashAndPassword`).
  `/auth/login`, `POST /api/users`, and `PATCH /api/users/:id/password` never
  accept or expose plaintext. Unknown emails burn a dummy bcrypt compare so
  login timing does not reveal which accounts exist.
- **Tokens:** signed `sub/exp/iat/jti` → `base64url.hmac-sha256` (compact, no
  JWT dependency). `POST /auth/logout` blacklists the token's `jti` for its
  lifetime; changing your password revokes the current session.
- **Rate limiting:** 10 login attempts/min/IP (brute-force), 300 API
  calls/min/user.
- **Input limits:** request bodies capped at 1 MiB (413 beyond); email, role and
  password policy (8+ chars, lower+upper+digit) validated on input.
- **Headers:** `nosniff`, frame `DENY`, no-referrer, restrictive CSP,
  permissions policy, `no-store` on auth/notification responses, HSTS in
  production.
- **CORS:** `ALLOWED_ORIGINS` allow-list only; disallowed origins never receive
  CORS headers and preflight is only honoured for allowed origins.
- **Authorization:** role middleware (`requireRole`) gates privileged actions.
  Every school *management* gate lists `RoleSuperAdmin` explicitly (the
  platform operator may act anywhere, mirroring `schoolScope`), while purely
  student-self gates (assignment completion, assessment submission) stay
  student-only so an operator can never pollute a learner's records. Per-record
  scoping lets staff read any record, students only their own (self-only
  `check-in`), and parents only their own children. `listUsers` hides
  super-admin rows from non-super-admins. Exam-type assessments
  (Mid-Term / End-of-Term / Mock / Diagnostic / Remedial) may only be *created*
  by school leaders (`superAdmin`/`schoolAdmin`/`headteacher`) — teachers keep
  creating quizzes, class tests, exercises, homework and vacation work
  (enforced inside `createAssessment`, pinned in `rbac_test.go`).
- Tests: `internal/security` (primitives) and `internal/httpapi/security_test.go`
  (login rate-limit → 429, tampered/expired/revoked tokens → 401, password
  non-leak, oversized body → 413, CORS, scoping → 403, user-validation).
  `internal/httpapi/rbac_test.go` pins the full role × endpoint matrix (who may
  create/promote/edit students, questions, assessments, announcements, mark
  notifications, submit for others, and student-list scoping counts); the
  client mirrors this contract in `test/rbac_access_test.dart`.

## Route map

### Auth
`POST /auth/login` · `POST /auth/logout` · `GET /auth/me`

### School & SIS (doc §8–10)
`GET/PUT /api/school` · `GET/PUT /api/school/term` · `GET /api/school/classes`
`GET/POST /api/students` (role-scoped) · `GET /api/students/:id`
`PATCH /api/students/:id` · `POST /api/students/:id/promote|graduate`
`POST /api/students/:id/pickup/authorize|revoke`
`GET/POST /api/users` · `PATCH /api/users/:id/password`
`GET /api/subjects`

### Attendance & safety (doc §12–13)
`GET /api/attendance/class/:classId/date/:date` ·
`PUT /api/attendance/class/:classId/date/:date`
`GET /api/attendance/students/:studentId/history|summary` ·
`POST /api/attendance/check-in` · `POST /api/attendance/correction`
`GET/POST /api/gate/events` · `GET /api/gate/students/:studentId`

### Question bank & AI generation (doc §17, §43)
`GET/POST /api/questions` · `PATCH/DELETE /api/questions/:id`
`GET /api/questions/ai/requests` · `POST /api/questions/ai/requests`
`POST /api/questions/ai/requests/:id/generate|publish|reject`

### Assessments & marking (doc §16, §18, §26, §54)
`GET/POST /api/assessments` · `GET /api/assessments/:id`
`POST /api/assessments/:id/blueprint` · `POST /api/assessments/:id/submit`
`POST /api/assessments/:id/verdicts` · `GET /api/assessments/:id/results`

### Analytics & interventions (doc §27–32)
`GET /api/analytics/students/:studentId/results|weak-topics`
`GET /api/analytics/classes/:classId/gaps?assessmentId=` · `GET /api/analytics/at-risk`
`GET/POST /api/interventions` · `GET /api/interventions/students/:studentId`
`POST /api/interventions/:id/status|reassessment` ·
`GET /api/interventions/:id/improvement`

### Communication (doc §36, §40)
`GET/POST /api/announcements` · `GET/POST /api/messages`
`GET /api/notifications/unread` · `POST /api/notifications/:id/read` ·
`POST /api/notifications/read-all`

### Assignments (doc §41)
`GET/POST /api/assignments` · `POST /api/assignments/:id/complete`

### Reports (doc §22, §33–34)
`GET /api/reports/students/:studentId/report-card` ·
`GET /api/reports/assessments/:id/class-results` (includes CSV body)

### Audit (doc §49)
`GET /api/audit` (superAdmin/schoolAdmin/headteacher)

## Project layout

```
cmd/server            entrypoint + config (env-driven)
internal/domain       models & enum constants (mirror of client core/models)
internal/store        Store interface + in-memory + PostgreSQL implementations + seed
internal/marking      computeEarned / grades / blueprint / analytics mirror
internal/security     bcrypt / password policy / opaque-token primitives
internal/httpapi      router, auth/middleware, handlers, reports
migrations/           embedded PostgreSQL schema (001_init.sql)
```

## Known follow-ups (roadmap)

- **`contextTODO()` propagation** — the Postgres store currently blocks on a
  plan for request-scoped cancellation/observability; the 55-method `Store`
  interface (and its in-memory partner) needs a mechanical
  `ctx context.Context` pass-through before deadlines/tracing are useful.
- **Out-of-scope modules documented in the product docs but not implemented:**
  the Next.js dashboard (uses `ALLOWED_ORIGINS` + the token flow), Redis-backed
  queues, and the real Python AI pipeline (FastAPI/Transformers) — the
  `/api/questions/ai/…` endpoints currently serve templated drafts in its place.

## Parity guarantees

- Question auto-marking (`mcq`/`trueFalse`) uses exact trimmed, lower-cased
  match — identical to the client (`submission.dart:computeEarned`).
- Blueprint generation uses subject/topic filter → subject fallback → shuffle →
  take n, identical to `AssessmentRepository.blueprintPick`.
- `gradeLetter`, gap ranking and at-risk thresholds use the client's cut-offs.
- Seed data is a verbatim port of `LocalStore` seeds (users, classes, students,
  attendance, gate, bank, assessments, submissions, interventions, messages,
  notifications, assignments).