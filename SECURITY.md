# Security policy

## Reporting a vulnerability

Please **do not** open a public issue for a security finding. Email the
maintainer (`roberto@solvanta.local`) with:

- the affected component (`lib/`, `backend/`, `migrations/`),
- a description of the issue and its impact,
- reproduction steps or a proof of concept, if you have one.

You should get an acknowledgement within a few working days. Please allow a
reasonable window for a fix before publishing details.

## Design notes worth knowing

These are the invariants the codebase is built around — a change that breaks
one of them is a security bug even if it "works":

- **The Go API is the only authorization boundary.** The Flutter client never
  talks to a database. Every guarded route requires
  `Authorization: Bearer <token>` and re-checks the *server-side* role; the
  client's role checks are UX only. The store keeps no knowledge of roles
  beyond what handlers ask for.
- **Offline-first reads are not a bypass.** Read paths may serve the local
  copy when the API is unreachable, but every *write* that carries authority
  (attendance, gate events, marks, role changes) goes through the API.
- **Credentials are never stored in clear.** The client hashes secrets at rest
  as `v2$salt$iterations$digest`; refresh tokens are stored hashed server-side;
  passwords are verified server-side (never shipped to a log).
- **No app-data backup.** `android:allowBackup="false"` — SharedPreferences
  holds the session, hash verifiers and student records, so it must not be
  copied off-device.
- **`SECRET` is mandatory in production.** `httpapi.NewServer` refuses to boot
  with `ENV=production` and an empty `SECRET`. In development the launcher
  generates one and keeps it in `.env` so sessions survive a restart.
- **`.env` is never committed.** It holds a database password and the signing
  key; `.gitignore` covers it and `.env.example` ships without values.

## Development-only caveats

Not vulnerabilities in a dev build, but never ship them:

- The seeded demo accounts (`admin@solvanta.app` / `admin123`, and the
  teacher/parent/student equivalents) exist so the app is instantly runnable.
  `main.go` only seeds when `shouldSeed(production)` allows it.
- `run-dev.cmd` binds and reports `127.0.0.1` by preference; `main.go`'s
  default `ADDR` is `:8080`, i.e. every interface. Set `ADDR=127.0.0.1` on any
  machine that is not behind a firewall.
