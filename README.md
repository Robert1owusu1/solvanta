# SOLVANTA

School management, assessment & student-safety platform for Ghanaian schools:
role-based dashboards for **admin, teacher, parent, student and staff**, with an
offline-first Flutter client and a production-style Go API kept in parity.

| Part        | Where                                                        |
|-------------|--------------------------------------------------------------|
| Client      | `lib/` (Flutter) · `test/`                                   |
| API         | `backend/` (Go + Gin, see `backend/README.md`)               |
| Storage     | PostgreSQL (schema in `backend/migrations`) or in-memory     |
| Infra       | `backend/Dockerfile` · `docker-compose.yml` · CI in `.github/workflows/ci.yml` |

## Roles & the RBAC contract

Every role sees only the dashboards and actions meant for it, on the client and
the API:

- **Super admin** (platform operator) — sees/acts in every school, but stays out
  of purely student-self actions (can't submit work or assessments *as* a pupil).
- **School admin / headteacher** — the full school-management grid (students,
  staff, fees, safety, assessments, audit, reports, …).
- **Teacher** — classroom: own students, marking, assessments, messages,
  interventions; **no** enrolment or admin surfaces.
- **Parent** — only their own children (arrival/departure, results, feedback).
- **Student** — only self (profile, results, assignments, own work).
- **Staff** — supporting duties (attendance, gate, announcements); no marking.

This is **locked in by tests**, not by convention:

- API: `backend/internal/httpapi/rbac_test.go` — full role × endpoint status
  matrix, student-list scoping, notification ownership, IDOR rejection.
- Client: `test/rbac_access_test.dart` — module-grid matrix per role, capability
  flags, dashboard routing, and the self-registration role picker
  (teacher/parent/student only).

## Run the app

```sh
flutter pub get
flutter run                 # device/emulator; adb reverse tcp:8080 tcp:8080
```

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
store. API URL priority: `--dart-define=SOLVANTA_API=…` → `SOLVANTA_API_URL` →
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

## Architecture decisions (recorded)

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