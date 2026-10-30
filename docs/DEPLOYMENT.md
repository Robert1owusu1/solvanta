# Deploying SOLVANTA

The plan is to put the **web app** into production first and keep improving the
Android app against the same backend. Both are built from the one Flutter
codebase in this repository and talk to the same API and database, so a fix to
the backend reaches both.

```
 Browser ──► web app (static files: build/web) ──┐
                                                 ├──► Go API (backend/) ──► PostgreSQL
 Android ──► app (APK / Play Store) ─────────────┘
```

No host has been chosen yet. Everything below works with any provider.

## 1. Database: PostgreSQL

- PostgreSQL. Developed and tested on version 18; use 18 in production to match.
- Create an empty database and a user for it that may create schemas.
  **Nothing else.** The API is required to run on PostgreSQL in production
  (it refuses to start without `POSTGRES_DSN`).
- Every school has its own schema (`school_<id>`), listed in `public.tenants`.
  At boot the API applies each file in `backend/migrations/` that a school's
  `schema_migrations` table doesn't list yet, in filename order, one
  transaction per file — so upgrades need no manual step. A new school (the
  super admin's `POST /api/schools`) gets its schema and migrations on
  creation.
- Back it up. Marks, attendance and fees live here.
- **Never** point `TEST_POSTGRES_DSN` (the test suite) at this database. The
  tests empty every table.

## 2. Backend API

Build the container from `backend/Dockerfile`, or a binary with
`cd backend && go build -o solvanta-api ./cmd/server`.

Set the environment from [`deploy/production.env.example`](../deploy/production.env.example):

| Setting | Why it matters |
|---|---|
| `ENV=production` | Requires `SECRET`, turns on HSTS and quiet logging, and keeps demo seeding off. |
| `SECRET` | Signs sign-in tokens. Generate with `openssl rand -hex 32`. Changing it signs everyone out. |
| `POSTGRES_DSN` | Without it the API runs **in memory and loses everything on restart**. |
| `ALLOWED_ORIGINS` | The web app's exact address (e.g. `https://portal.yourschool.com`). Without it the browser blocks every request. |
| `ADDR=:8080` | The default listens on loopback only, which a proxy or container cannot reach. |
| `TRUSTED_PROXIES` | Your host's proxy range, so each visitor's real IP reaches the login throttle. |
| `SEED` | Leave unset. It creates demo accounts with public passwords. |

At boot the log states the store, the environment and which OCR engine is
active, e.g. `listening on :8080 (env=production)`. Check it on every deploy.

Health check: `GET /health` returns `{"status":"ok"}` while the process is up,
with storage errors reported alongside rather than as "down".

## 3. Web app

```sh
scripts/build-web.sh https://api.yourschool.com
```

Upload the contents of `build/web/` to any static host.

- The API address lives in `build/web/config.json` (`{"api": "…"}`), which the
  app reads at startup. Change the address by editing that file — no rebuild.
  `{"api": ":8080"}` means the API on the same host as the page, on port 8080.
- Without `config.json` the app runs as an offline demo in each visitor's
  browser, which is why the script refuses to build without an address.
- The app uses `#/` links, so the host needs no rewrite rules. For a sub-path
  (`yourschool.com/portal/`) run with `BASE_HREF=/portal/`.
- Serve it over HTTPS. Browsers block an HTTPS page from calling an HTTP API.

### Same site or separate?

- **API on its own address** (`api.yourschool.com`): set `ALLOWED_ORIGINS` to
  the web app's address.
- **One address with a proxy** (`yourschool.com` for the site, the API behind
  the same host): build with that same address. Then the browser makes no
  cross-site calls, and `ALLOWED_ORIGINS` can stay empty.

## 4. Android app

Build against the same API:

```sh
flutter build apk --release --dart-define=SOLVANTA_API=https://api.yourschool.com
```

Release builds are currently signed with the **debug key**
(`android/app/build.gradle.kts`). That is fine for testing, but the Play Store
needs a private upload key set up first. Never commit that key: `.gitignore`
already excludes `*.key` and `*.pem`.

The app works offline and syncs when it reaches the API. The web app does the
same, but browser storage is small (about 5 MB), so photos queued for upload
while offline fill it quickly. Use the Android app for photographing scripts.

## 5. Before each deploy

```sh
scripts/check.sh                                  # analyze + all tests
TEST_POSTGRES_DSN=postgres://…/throwaway scripts/check.sh   # + PostgreSQL tests
```

CI (`.github/workflows/ci.yml`) runs the same checks, including PostgreSQL, on
every push to `main`.

## Known limits to plan around

- **OCR keys:** none are installed, so OCR uses the mock engine until
  `MATHPIX_*` / `GOOGLE_VISION_API_KEY` are set. Read the privacy notes in
  `backend/README.md` first.
- **One API instance:** the login throttle and signed-out tokens are kept in
  memory, so run a single API instance (restarts are fine). Running several
  behind a load balancer needs those moved into the database first.
