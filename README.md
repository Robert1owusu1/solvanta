# SOLVANTA

School management, assessment & student-safety platform for Ghanaian schools:
role-based dashboards for **admin, teacher, parent, student and staff**, with an
offline-first Flutter client and a production-style Go API kept in parity.

| Part        | Where                                                        |
|-------------|--------------------------------------------------------------|
| Client      | `lib/` (Flutter: one codebase for web **and** Android) · `test/` · `integration_test/` |
| Web shell   | `web/` (index.html, icons, manifest)                         |
| API         | `backend/` (Go + Gin, see `backend/README.md`)               |
| Storage     | PostgreSQL (schema in `backend/migrations`) or in-memory     |
| Deploy      | `deploy/` (production settings template) · `docs/DEPLOYMENT.md` |
| Scripts     | `scripts/check.sh` (all checks) · `scripts/build-web.sh` (production web build) |
| Docs        | `docs/` (deployment guide, project documentation)            |
| Infra       | `backend/Dockerfile` · `docker-compose.yml` · CI in `.github/workflows/ci.yml` |

```
SOLVANTA/
├── lib/              Flutter app: core/ (models, storage, sync, API client) + features/
├── test/             Flutter unit, widget and RBAC tests
├── integration_test/ on-device RBAC run
├── web/  android/  ios/  linux/  macos/  windows/   platform shells
├── backend/          Go API
│   ├── cmd/server/       entry point (reads the environment)
│   ├── internal/         httpapi (routes, RBAC) · store (memory + Postgres) · marking · ocr · domain
│   └── migrations/       SQL schema, applied automatically at boot
├── deploy/           production environment template
├── docs/             DEPLOYMENT.md and the project documentation
└── scripts/          check.sh · build-web.sh
```

Deploying the web version: see [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

## Roles & the RBAC contract

Every role sees only the dashboards and actions meant for it, on the client and
the API:

- **Super admin** (platform operator) — sees/acts in every school, but stays out
  of purely student-self actions (can't submit work or assessments *as* a pupil).
- **School admin / headteacher** — the full school-management grid (students,
  staff, fees, safety, assessments, audit, reports, …).
- **Teacher** — classroom: own students, marking, assessments (classroom
  types: quizzes, class tests, exercises, homework, vacation work), messages,
  interventions; **no** enrolment or admin surfaces. Exam-type assessments
  (Mid-Term / End-of-Term / Mock / Diagnostic / Remedial) are created by school
  admins / headteachers only.
- **Parent** — only their own children (arrival/departure, results, feedback).
- **Student** — only self (profile, results, assignments, own work).
- **Staff** — supporting duties (attendance, gate, announcements); no marking.

Marking follows the same lines: a teacher captures, marks and writes marking
schemes for **their own class** only; school admins / headteachers for any
class. A marking scheme is the answer key, so students, parents and staff can
never read one. A pupil cannot resubmit a paper once it is in, so a marked
result cannot be overwritten.

This is **locked in by tests**, not by convention:

- API: `backend/internal/httpapi/rbac_test.go` — full role × endpoint status
  matrix, student-list scoping, notification ownership, IDOR rejection.
- Client: `test/rbac_access_test.dart` — module-grid matrix per role, capability
  flags, dashboard routing, and the self-registration role picker
  (teacher/parent/student only).

## Run the project

Run the API, then the mobile and/or web client, each in its own terminal.
Without the API both clients still start, offline on the seeded `LocalStore`.

### 1. Backend

```sh
cd backend
ALLOWED_ORIGINS=http://localhost:5000 go run ./cmd/server
```

Listens on `127.0.0.1:8080` with the in-memory store (see
[Run the backend](#run-the-backend) for PostgreSQL and Docker).
`ALLOWED_ORIGINS` is only needed for the web client: the API sends CORS
headers to allow-listed origins only, so the browser blocks every call
otherwise.

> On this machine Go lives on the external drive; if `go` is not found, add
> `export PATH="$PATH:/mnt/devdrive/DevTools/go/go/bin:$GOPATH/bin"` to
> `~/.bashrc` and open a new terminal.

### 2. Mobile app

```sh
flutter pub get
adb reverse tcp:8080 tcp:8080   # lets the device reach the API on 127.0.0.1:8080
flutter run                     # pick the Android device/emulator
```

### 3. Web app

```sh
flutter run -d chrome --web-port 5000                              # Chrome/Chromium/Edge
flutter run -d web-server --web-port 5000 --web-hostname localhost # any browser, e.g. Firefox
```

Keep the port at `5000` so the origin matches `ALLOWED_ORIGINS` (Flutter
picks a random port otherwise). With `web-server`, open
`http://localhost:5000` yourself — `localhost`, not `127.0.0.1`, which is a
different CORS origin — and press `R` + refresh the tab to pick up changes. If
Chromium isn't found, set `CHROME_EXECUTABLE=$(which chromium)`. On the web,
biometrics are skipped and scan images are only partly supported.

Point either client at another API with
`--dart-define=SOLVANTA_API=http://<host>:8080`.

> ⚠️ **Sideloading gotcha:** `flutter test integration_test/…` rewrites
> `build/app/outputs/flutter-apk/app-debug.apk` with a *test-listener* entrypoint
> (`flutter_test_listener/listener.dart`) that just waits for the test harness.
> If you install that APK on a phone it launches to a blank black screen (no app
> UI ever builds). After any integration-test run, always rebuild the APK before
> installing on a device:
> `flutter build apk --release --target-platform android-arm64`.

## Run the backend

```sh
cd backend
go run ./cmd/server                    # in-memory store, seeded demo data
POSTGRES_DSN="postgres://…" go run ./cmd/server   # PostgreSQL, schema auto-applied
```

Docker stack (API + Postgres):

```sh
docker compose up --build
```

Local Postgres without Docker on this machine (`/mnt/devdrive/DevTools/postgresql`,
extracted binaries, no sudo): see `backend/README.md` → *Local PostgreSQL*.

## Live API wiring

The app runs fully offline on its seeded `LocalStore`; with an API configured,
repositories read through `RemoteDataSource` and mirror results into the local
store. Gate events follow the same rule: [`SafetyRepository`](lib/features/safety/safety_repository.dart)
records locally first, then pushes to `POST /api/gate/events` (best-effort; the
offline outbox retries it), adopting the server-assigned id so a school with
several gate devices sees one deduplicated trail. API URL priority: `--dart-define=SOLVANTA_API=…` → `SOLVANTA_API_URL` →
`http://127.0.0.1:8080`. The live-parity suite asserts app seed/models match the
API byte-for-byte:

```sh
SOLVANTA_API_URL=http://127.0.0.1:8080 flutter test test/api_parity_test.dart
```

## Verify (both suites)

```sh
cd backend && go vet ./... && go test ./...   # TEST_POSTGRES_DSN adds the PG path
flutter analyze && flutter test
```

## On-device acceptance gate

The same RBAC contract is driven through the **real app** on a connected phone
(real login screen, real rendered grids, live session): each seeded role signs
in and must see exactly its own module grid — including that no other role's
tiles ever appear:

```sh
flutter test integration_test/rbac_on_device_test.dart -d <device-serial>
```

Assertions are scoped to the module GridView, so overview stat-cards that share
words (e.g. the "Students" count) can't fake a leak. Run it against the live API
with `adb reverse tcp:8080 tcp:8080` and the backend from above.

## Demo logins (seeded)

| Role        | Email                 | Password    |
|-------------|-----------------------|-------------|
| Super admin | super@solvanta.app    | super123    |
| Admin       | admin@solvanta.app    | admin123    |
| Headteacher | head@school.gh        | head123     |
| Teacher     | efua.mensah@school.gh | teacher123  |
| Parent      | ama.owusu@school.gh   | parent123   |
| Student     | kojo.owusu@school.gh  | student123  |

Every seeded student has a linked parent account (`USR-PRN-002`…`008`, all
`parent123`) so gate arrival/departure notices reach every family:

| Student        | Parent account (email)            |
|----------------|-----------------------------------|
| STU-002 Akosua | akua.boaduwaa@school.gh          |
| STU-003 Kwabena| adwoa.adjei@school.gh            |
| STU-004 Abena  | kwabena.serwaa@school.gh         |
| STU-005 Yaw    | nana.darko@school.gh             |
| STU-006 Maame  | efua.adwoa@school.gh             |
| STU-007 Kofi   | esi.manu@school.gh               |
| STU-008 Esi    | ama.amponsah@school.gh           |

## Architecture decisions (recorded)

- **Gate check-in by scanning** — the student ID card carries a compact JSON QR
  payload (`student_qr_card.dart`); the check-in screen's camera scanner
  (`student_id_scanner_screen.dart`, `mobile_scanner`) decodes it, then the staff
  member still confirms with the standard tile — a scan never checks anyone in
  by itself. Camera permission is requested at first use; typing an ID remains
  as the fallback.
- **Student ⇄ parent links for every seeded student** — arrival/departure/pickup
  notices resolve `student.parentUserId`; the fallback for genuinely unlinked
  students stays staff-visible so nothing is silently missed.
- **Offline-first client** — local store is the source of truth until a live API
  is configured; auth, fees and messages go through the API when present. The
  Go API mirrors the client's seed and business logic (marking, blueprint,
  analytics) so either path behaves identically.
- **Simulated AI** — `POST /api/questions/ai/…` produces **templated drafts**
  locally; the Python/FastAPI/Transformers pipeline described in the docs is a
  future module, not wired up.
- **PostgreSQL 18 without sudo** — extracted from official `.deb` into
  `/mnt/devdrive/DevTools/postgresql` with a `manage.sh` start/stop wrapper
  (see backend README); `.docker/…` volumes serve Compose users instead.
- **Super admin as explicit operator** — named on every management `requireRole`
  gate (never implicit), excluded from student-only records.
- **Notification deep links** — tapped notifications resolve kind → destination
  module from the same `modulesFor(role)` grid the dashboards use
  (`lib/core/notifications/deep_link.dart`), so routing can't drift from the
  module registry.