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

# production (PostgreSQL; schema applied at boot, demo dataset seeded once)
export POSTGRES_DSN="postgres://solvanta:change-me@db:5432/solvanta?sslmode=disable"
ENV=production SECRET=$(openssl rand -hex 32) PORT=8080 go run ./cmd/server

# skip the demo dataset on an existing production database
POSTGRES_DSN="$POSTGRES_DSN" SEED=false go run ./cmd/server

# tests (PostgreSQL integration tests run when TEST_POSTGRES_DSN is set)
go test ./...
TEST_POSTGRES_DSN="postgres://postgres@127.0.0.1:5432/postgres?sslmode=disable" go test ./...
go vet ./...
```

### Local PostgreSQL (this machine, no sudo)

The system has no passwordless sudo, so a self-contained PostgreSQL 18 runs
entirely from the external drive — extracted binaries plus a managed data dir,
no system packages installed:

```sh
/mnt/devdrive/DevTools/postgresql/manage.sh start    # boot on 127.0.0.1:5433
/mnt/devdrive/DevTools/postgresql/manage.sh stop
# DSN (user solvanta, trust auth — local dev only):
POSTGRES_DSN="postgres://solvanta@127.0.0.1:5433/solvanta?sslmode=disable" \
  SEED=true go run ./cmd/server

TEST_POSTGRES_DSN="postgres://solvanta@127.0.0.1:5433/solvanta?sslmode=disable" go test ./...
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
> re-run against an already-seeded database.

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