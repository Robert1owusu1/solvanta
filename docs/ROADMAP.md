# SOLVANTA Roadmap / Backlog

Status as of **2026-11-05**. This tracks what is built and what is deliberately
deferred ("build later"). For shipped detail see `CHANGELOG.md`.

## ✅ Built

Core & assessment: manual scores, score sheet/gradebook, CSV/XLSX import
(scores, payments, students), year-end promotions, timetable, OCR background
queue (scan → read → confirm), homework upload (photo capture → crop → submit,
backend + UI).

Tenancy & commercial: independent teacher workspaces, plans/pricing
(contact-sales; only the free tier is self-serve — the platform never takes
money in-app), usage metering, workspace transfer.

People & safety: student health/emergency records **+ in-app editor**, gate
events, interventions, parent meetings.

Communication: parent↔teacher messaging, announcements, push notifications,
email + self-service password reset.

Operations & platform: teacher **cover/substitution** planner, outbound webhooks
(HMAC-signed), MFA/TOTP, Prometheus metrics, hash-chained tamper-evident audit,
public OpenAPI spec + `/docs` viewer, analytics / learning profiles, GHCR Docker
deploy + CI/CD.

## 🔨 Deferred — build later

Ordered cheapest / highest-value first. None of these have code yet.

| # | Feature | Scope / approach notes |
|---|---------|------------------------|
| 1 | **Exam seating plans** | Generate a seating + invigilation layout for an exam from a class/room roster (spacing rules, print/export). Self-contained; reads existing students + classes. Needs a `rooms` concept (see #2) or a free-text room. |
| 2 | **Room booking** | A rooms registry + conflict-free booking against timetable slots. Store via a `rooms` + `room_bookings` record kind; check overlaps on save. Unlocks richer #1. |
| 3 | **RSVPs / event forms** | Parent-engagement depth beyond messaging: events with attendance replies (going / not going) and simple structured forms (consent, trips). New `events` + `rsvps` record kinds; notify guardians; roll up responses for staff. |
| 4 | **Library / inventory** | Asset & book catalogue with lending/returns and overdue tracking. New `inventory_items` + `loans` record kinds; scoped reads; audit on checkout/return. |
| 5 | **Transport** | Routes, pickup points, and vehicle/driver assignment; optionally link to gate events for pickup verification. New `transport_routes` + per-student assignment. |
| 6 | **GES EMIS export** | National-reporting export file in the Ghana EMIS format. Pure read + format on the backend (new endpoint), no new storage. Confirm the current EMIS schema/spec before building. |
| 7 | **OneRoster export** | OneRoster CSV/REST interop so rosters sync with other systems. Read + format; new export endpoint. |
| 8 | **Golden PDF tests** | Test hardening: pin report-card PDF output against a committed golden so layout/glyph regressions are caught. Watch for font-dependent flakiness across environments. |

### Blocked / out of scope

- **SSO (Google / Microsoft)** — ⚠️ **blocked**: needs OAuth client
  credentials (client id/secret, redirect URIs) from the account owner before it
  can be implemented. Not started.
- **i18n (English + Twi)** — **out of scope** per owner instruction
  (2026); the platform stays English-only for now.

## Conventions when picking these up

- Keep the Go API and Flutter client in parity; model new collections as
  `domain.Record` kinds in `backend/internal/httpapi/records.go` with an explicit
  read scope + writer roles (see `cover_assignments` for the pattern).
- Offline-first on the client: persist locally, mirror to
  `/api/records/<kind>/<id>`, and add a pull mirror in `server_sync.dart`.
- Each feature ships as its own tested batch: `go test ./...`, `gofmt`,
  `flutter analyze`, `flutter test`, a `CHANGELOG.md` entry, then commit and push
  **to `main` only** (fast-forward; never push the feature branch).
