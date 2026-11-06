# SOLVANTA — Feature: Manual Score Entry, Score Sheet, and the Independent Teacher Plan

You are working in the SOLVANTA repo (Flutter client in `lib/`, Go + Gin API in `backend/`, PostgreSQL with one schema per school via `backend/internal/store/tenants.go`). Read `README.md` (RBAC contract), `backend/internal/httpapi/server.go` (routes), `backend/internal/domain/models.go`, `backend/migrations/`, `lib/features/assessment/`, `lib/features/marking/` and `lib/features/auth/` before changing anything.

Keep the existing rules in force: client and API stay in parity (`test/api_parity_test.dart`), RBAC is enforced on both sides and locked in by tests (`backend/internal/httpapi/rbac_test.go`, `test/rbac_access_test.dart`), writes are offline-first through `SyncQueue` with client-chosen idempotent ids, and the UI uses the existing brand tokens and `Sv*` widgets. Don't break any existing test.

Build this in four phases. Finish each phase, with its tests passing, before you start the next one. Stop after each phase and give a short summary of the files you changed.

---

## Phase 1 — Manual score entry (schools that don't use AI marking)

### Problem
At the moment a score can only come from an AI/OCR marking draft or a question-by-question submission. `Assessment.totalMarks` is derived from `questions`, so an assessment with no questions has a total of 0. Some schools mark on paper and only want to record the final score for each student.

### Requirements
1. **Marking mode setting**
   - Add a school-level setting `markingMode`: `ai` | `manual` | `both` (default `both`). Only `schoolAdmin` / `superAdmin` can change it, from the school admin settings screen.
   - `manual` hides the AI capture/marking entry points for that school, both in the UI and on the API (return 403 on the AI marking routes). It does not delete data that already exists.
2. **Assessments that work without questions**
   - Add an optional `maxScore` to `Assessment`, in Go, Dart and the migration. The effective total is `maxScore` if it is set, otherwise the sum of question marks. Every place that currently calls `totalMarks` / `TotalMarks()` must use the effective total.
   - In the assessment builder, a teacher can create a "score-only" assessment with a title, type, subject, class, date and max score, and no questions.
3. **Recording a score manually**
   - Add `source` to `Submission`: `ai` | `manual` | `online`. A manual submission has `earned` set and empty `answers`.
   - Add an optional `remark` and `absent` (bool) to each score. Absent is not the same as zero, and averages must exclude absent students.
   - Validate that `0 ≤ score ≤ effective total`. Allow half marks.
   - **Single entry:** open an assessment and see its class roster as a list. Each row has a score field, an absent toggle and a remark field. Saving works offline.
   - **Bulk upload:** add a "Download template" button that generates an `.xlsx` (the `excel` package is already a dependency) and a `.csv` already filled with the roster: `studentId, admissionNo, studentName, score, absent, remark`, with the assessment title and max score in the header rows. The teacher fills it in and uploads it. Before anything is saved, show a preview that marks each row valid, warning or error (unknown student, score over the max, duplicate row, non-numeric value). The teacher then confirms. Match rows on `studentId` first and `admissionNo` second. Never match on name alone.
   - New endpoints:
     - `PUT /api/assessments/:id/scores/:studentId` for a single score
     - `POST /api/assessments/:id/scores/bulk` for many scores. The request body is an array, the operation is idempotent and runs in one transaction, and the response returns the result for each row.
   - RBAC: the same as marking. A teacher can only record scores for their own class. Admins and headteachers can record for any class. Students, parents and staff cannot write scores.
   - **Overwrite rule:** a manual score can be edited by the teacher until the term is finished (`finished_terms`). Every edit writes an audit entry with the old value, the new value and who made the change. If a score is already `marked` from AI, a manual edit needs an explicit "override" confirmation and is audited the same way.
4. **Tests:** Go tests for validation, RBAC, idempotent bulk replay, absent handling and the 403 in `manual` mode. Dart tests for template generation, upload parsing and the preview validation.

---

## Phase 2 — Score sheet (gradebook) and export

1. On the assessment side, add a **Score Sheet** screen for each class and subject with students as rows and assessments as columns. Each cell shows the score out of the max score and is marked `AI`, `Manual` or `Absent`. Empty cells are highlighted. Add a column for each student's term total that uses the school's existing grading config (`grading_configs`: the class-score/exam split and grade bands), plus the position in class.
2. Filters: term, class, subject, and assessment type.
3. Tapping a cell opens single-score entry (Phase 1). Tapping a column header opens that assessment.
4. **Download:** export the sheet as `.xlsx` and PDF (reuse the patterns in `lib/features/fees/fees_pdf.dart` and `report_card_pdf.dart`). Also allow export of a single assessment's results. On mobile, share with `saveAndShareFile`.
5. Endpoint: `GET /api/reports/score-sheet?classId=&subjectId=&term=`. Keep the same RBAC as `classResultsReport`.
6. Tests: totals with weighting, absent handling, the RBAC matrix, and export generation.

---

## Phase 3 — Independent Teacher workspace

### Problem
A teacher whose school is not on SOLVANTA should still be able to use it to automate their own work. Today, self-registration in `auth_repository.dart` hardcodes `schoolId: 'SCH-001'`, so every self-registered teacher lands in the default school. That is a data-isolation bug and has to be fixed as part of this phase.

### Requirements
1. **Workspace as a tenant:** when a teacher self-registers as "Independent teacher", create a new tenant through `tenants.Create` with `school.kind = 'independent'` and `ownerUserId` set to the teacher. Reuse the existing schema-per-tenant isolation instead of filtering by user. Normal schools get `kind = 'school'`. Add `kind` to `schools` in a migration and default existing rows to `'school'`.
2. **What an independent teacher can do (inside their own workspace only):**
   - Create their own classes and register students into them (name, gender, admission/index no. optional). They can also bulk-import students from an `.xlsx`/`.csv` template, using the same preview-then-confirm pattern.
   - Create assessments of any type in their own workspace. The exam-type restriction only applies inside schools.
   - Use AI marking (capture → draft → review → finalize) and manual score entry (Phase 1).
   - Use the score sheet and all downloads (Phase 2).
3. **What they cannot do:** fees and invoices, gate/safety, SMS, staff management, parent/student logins, announcements, report-card approval workflow, school-wide analytics, and audit screens. Hide these in the module grid (`lib/features/home/dashboards.dart`) and return 403 on the API. Add a capability check that depends on `school.kind` (for example `capabilities.forSchool(kind, plan)`) instead of scattering `if independent` checks. Lock the matrix down in `rbac_test.go` and `rbac_access_test.dart`.
4. **Transfer to a school (build it):** when the teacher's school joins SOLVANTA, a super admin can move the teacher's workspace into that school's tenant.
   - The super admin picks the source workspace and the target school, then sees a **dry-run preview** listing the classes, students, assessments, scores, marking drafts and scan images to be moved, plus any conflicts (class name clashes, duplicate admission numbers, email clash for the teacher account).
   - For each conflict the super admin chooses whether to merge into an existing class or create a new one.
   - The move runs in one transaction. Ids are kept, or remapped with a stored old→new map so that offline clients replaying old ids still land correctly. The teacher's account becomes a normal `teacher` in the school, and the school's RBAC applies from that point (exam types become admin-only again).
   - The independent workspace is then archived as read-only and never deleted automatically. Its subscription is closed.
   - Endpoints: `POST /api/schools/:id/transfers/preview` and `POST /api/schools/:id/transfers`, both super admin only. Every transfer is audited in both tenants.
   - Tests: preview accuracy, conflict handling, the move being all-or-nothing, the teacher's role after the move, and the old workspace being read-only.
5. **Privacy:** independent teachers are registering children's data, so they must accept a short data-protection notice at registration. Store the acceptance with a timestamp.

---

## Phase 4 — Plans, pricing and free vs paid features (super admin)

### Context: testing first, pricing later
During the testing phase, independent teachers get **every** feature with **no** limits and pay nothing. After testing, the super admin will decide which features are free, what the limits are, and the prices. All of that must be **configurable from the super admin screen with no code change or redeploy**. Build the full machinery now, but ship it switched off.

1. **Platform billing switch:** add a platform setting `billingMode` with the values `testing` | `live`, stored in `public` and editable by the super admin only. It defaults to `testing`.
   - In `testing` mode, every limit check passes and no invoices are generated. Usage is **still counted**, so you have real numbers to base prices on.
   - Show a small "Testing — free access" badge in the independent teacher's Account tab.
   - Switching to `live` asks for confirmation, is audited, and only takes effect from a start date the super admin picks. Before that date, teachers see a banner warning them of the change. Switching back to `testing` is allowed.
2. **Feature catalogue:** define every gated feature once, in a single list shared by Go and Dart. Examples: `students.register`, `students.bulkImport`, `marking.ai`, `scores.manual`, `scores.bulkUpload`, `scoreSheet.view`, `export.xlsx`, `export.pdf`, `questionBank`, `aiQuestionGen`, `analytics.class`, `transfer.toSchool`. The capability check from Phase 3 reads from this list.
3. **Plans** (platform-wide, in `public`, not per tenant):
   - `plans(id, name, kind ['independent','school'], is_free_tier bool, price_per_student_month, price_per_student_term, currency 'GHS', active, created_at, updated_at)`. Store amounts as integer pesewas, the same way `payments.amount` does.
   - `plan_features(plan_id, feature_key, enabled bool)` controls which features a plan includes.
   - `plan_limits(plan_id, limit_key, value NULLABLE)` holds limits such as `max_students`, `max_classes`, `ai_pages_per_month` and `exports_per_month`. **NULL means unlimited.**
   - Seed one plan, "Independent — Testing", with every feature enabled, all limits NULL and price 0.
4. **Super admin screen "Plans & Pricing":**
   - Create, edit, clone and deactivate plans.
   - Tick which features each plan includes.
   - Set each limit, or leave it empty for unlimited.
   - Set both the monthly and termly price per student.
   - Show a live preview line, for example: "A teacher with 45 students pays GHS X / month or GHS Y / term."
   - Price and limit changes apply from the next billing period, never retroactively. Keep a `plan_price_history` row for each change and audit it.
   - Let the super admin assign a plan to one tenant, or move all independent teachers from one plan to another, with a preview of how many are affected.
5. **Subscriptions:** `subscriptions(tenant_id, plan_id, billing_cycle ['month','term'], period_start, period_end, status ['free','testing','active','past_due','cancelled'])`.
   - **Billable students** are the peak number of active students in the period, so removing students just before billing doesn't lower the bill.
   - Invoice amount = billable students × the price for the chosen cycle. Show this calculation on the invoice. The teacher chooses monthly or termly billing when they move to a paid plan.
6. **Enforcement (live mode only):**
   - When a teacher reaches a limit or uses a feature their plan doesn't include, block only new actions (new AI marking, new student registration, a new export over the limit). Show a clear upgrade sheet explaining which limit was reached and the price.
   - **Never** block reading, editing existing scores, or downloading data the teacher already has.
   - A `past_due` subscription gets a configurable grace period (days) before blocks apply.
   - Enforce limits on the API. The UI check is only for a better experience.
7. **Usage counters:** keep counts per tenant per month (students, classes, AI-marked pages, exports, OCR cost) by hooking into the marking-draft finalize path and reusing `backend/internal/ocr/cost.go`. Add a super admin "Usage" screen that shows each independent teacher's usage against the cost to you, so you can price from real testing data. Allow export of this screen to `.xlsx`.
8. **Payment collection:** leave a `PaymentProvider` interface with a mock implementation. Do not integrate a real gateway in this phase. Paystack or Hubtel mobile money will come later.
9. Tests:
   - In testing mode, nothing is blocked and usage is still counted.
   - A NULL limit means unlimited.
   - A disabled feature returns 403 in live mode only.
   - Price calculation for both cycles and the peak-count rule.
   - Free-tier blocking never blocks reads or exports of data the teacher already has.
   - Price changes are not retroactive.
   - The grace period works.
   - Pricing RBAC: super admin only.
   - The switch from testing to live respects its start date.

---

## Definition of done (every phase)
- `scripts/check.sh` passes: `flutter analyze` clean, `flutter test` green, `go test ./...` green.
- Migrations are additive and idempotent (`IF NOT EXISTS`), and they work on the in-memory store and on Postgres.
- New screens follow the existing shell (`SvScreenHeader`, brand tokens), work on web and Android, and show skeleton, empty and error states.
- Add a CHANGELOG.md entry for each phase.
