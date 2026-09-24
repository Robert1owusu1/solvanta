# SOLVANTA — persistent task summary

## Objective
- (DONE, earlier session) Teacher-dashboard module phase system ("My Students" → "Academic Calendar", Live/Beta/New color-coded chips) + brand/animation/transition sweep across every feature screen + fresh APK rebuild/install/verify.
- (DONE, earlier session) Senior-UI/UX redesign of the dashboard module area and the screens opened from it: shared branded gradient screen header on every module screen, new 2-column dashboard module grid, chip filters + styled search on Students, avatar tiles across list screens, softer lifted cards, all verified on-device.
- (DONE, this session) Brand-token enforcement sweep (user supplied palette = existing tokens) + full app-shell/navbar rebuild (bottom NavigationBar, 4 tabs) + premium auth screens.
- (DONE, feature pass) Every suggested feature EXCEPT i18n: dark mode, pull-to-refresh, global search, haptics, skeletons, offline sync queue, notifications, biometric/PIN lock, fees & payments, parent↔teacher messaging threads, offline-lite/data-saver, QR student IDs, report-card PDFs, accessibility audit. Detail below.

## Feature pass (this session)

### Shell + platform wiring (lead)
- `lib/app.dart`: `ConnectivityMonitor.start()` + `NotificationService.init()` + `configureOnNotificationOpened` after `AppSettings.load()`; `AppLockGate` wraps app content **inside** the builder's scaled `MediaQuery` (agent D said outside — that would have dropped large-text on the lock screen).
- `dashboard_scaffold.dart`: `SyncStatusBanner()` permanently above the `IndexedStack` (renders nothing when idle); `SvRefresh` pull-to-refresh on Home/Modules/Account (real re-fetch: students + badge + overview stamp, `AlwaysScrollableScrollPhysics`); search + settings header icons and Account rows; `svHaptic` on tabs/header actions/module cards/account rows; `Semantics` on nav bar + every tappable card/row.
- `home_overview.dart`: `_OverviewPlaceholder` deleted → `SvCardSkeleton(lines: 4)`.
- Manifest: `RECEIVE_BOOT_COMPLETED` + both `flutter_local_notifications` boot receivers. `timezone ^0.10.1` promoted to a direct dep (dropped the `depend_on_referenced_packages` ignore).
- `dashboards.dart` entries added: Report Card Designer, Fees & Payments (admin), My Fees (parent/student), My ID (student); `student_profile_screen` gained "Show student ID card".

### Delivered by 3 parallel agents (disjoint dirs, integrated by lead)
- **Offline sync + notifications** (`lib/core/sync/`, `lib/core/notifications/`): `SyncQueue`, `ConnectivityMonitor`, `offlineLite`/`cacheTtl`, `SyncStatusBanner`, `NotificationService`, `NotificationBridge` (wired into `NotificationsRepository.push`); `ApiClient` auto-enqueues on network failure.
- **Reports + messaging** (`lib/features/reports/`, `communication/`, `models/message.dart`): 3 interchangeable report-card PDF templates (classic/modern/transcript) + preview/share screen; threads with `MessageState` queued→sent→delivered→read, `markRead` on open/scroll, receipt glyph+label, offline send queued.
- **Security** (`lib/features/security/`): `AppLockGate` (Stack cover + `ModalBarrier` above the Navigator ⇒ covers routes/dialogs/sheets; 45 s grace; `motionOff` ⇒ instant), `LockScreen`, `PinPad` (Semantics per key), `LockSettingsSection` (in Settings).
- **Fees + QR** (`lib/features/fees/`, `students/student_qr_*`): fee structures/invoices/payments/receipts, firm-commit `recordPayment`, school+student totals, PDF receipt, offline enqueue; `StudentQrCard`/`StudentQrScreen` (QR on pure white, PNG share, scan stub).

### Lead fixes to agent integration (real bugs, not cosmetics)
- `SyncQueue.registerHandler` was **first-wins** and `ApiClient` + `MessagesRepository` fought over one slot → either delivered messages stayed "Queued" forever, or `ApiClient` got locked out and the banner backlog never cleared. Added an independent **`registerObserver`** slot (runs after a successful delivery replay, ignored result; decides on its own when no delivery handler exists).
- Fees `_syncPayment` correctly no-ops when `!ApiClient.isConfigured` → no permanent banner in this local build.

### Accessibility audit — `.opencode/a11y-audit.md` (7 issues fixed)
- New token **`AppColors.goldFg`** (light `#8A6100` / dark `#F5C24B`): brand gold `#E3A008` is 2.26:1 on white → decorative only (hairlines/large glyphs); "New" pill went 2.06:1 → 5.06:1, calendar marker 2.26:1 → 5.54:1.
- `SvStatusBadge` tint `.12` → `.06` (Correct 4.20→4.54, Needs review 4.25→4.64, Not attempted 4.29→4.61); `successBg #EAF6EE → #F1F7F5` (4.43→4.54). **Spec'd state hexes untouched — only their backgrounds moved.**
- 7 icon-only buttons given `tooltip:` (all of `lib` now tooltip-complete). `SvEntrance`/`SvPressScale`/`SvAnimatedNumber` honour `motionOff` + OS `disableAnimations`. Password autofill + `done` action; `semanticsLabel` on the spinner; error state is a `liveRegion`; shimmer blocks `ExcludeSemantics`.

## This session — palette enforcement + navbar
- User palette confirmed identical to existing `AppTheme`/`AppColors`. Work = enforce it + fix 60/30/10 violations + build navbar.
- `app_theme.dart`: added formal navy ramp `AppTheme.navy900/700/500/400/300/200/100/50` + `navyRamp` list (deep→light). Added `navigationBarTheme` (surface bg, brand .10 indicator, selected=brand w800 11.5), `dialogTheme` (r22, no surfaceTint), `bottomSheetTheme` (r26 top, drag handle).
- Off-palette hexes eliminated: `#7A5AF8`/`#0E9384`/`#C026D3` (timetable subject palette → navy ramp + gold) and stray `#47719C`/`#9FB0CD`/`#7E93B8`/`#5F86AE` (notifications kind tints, analytics grade bars, resources kind tint) → all now `AppTheme.navyNNN` tokens. `resource.dart` keeps raw ARGB ints (pure-Dart file) with comment noting they mirror the ramp.
- Global `Colors.grey` sweep: 30 files, ~71 sites → `AppColors.muted/body/border`. `PdfColors.grey600` in reporting_service.dart deliberately untouched (PDF package enum, script shielded it).
- 60/30/10 fix: full-bleed navy→**gold** gradients replaced with `navy900→navy700` (login bg, dashboard hero). Gold retained as ~10% accent: 3×56 hairline under hero/wordmark, `New` chip sparkle, section-title bars.

## Navbar / app shell (dashboard_scaffold.dart, rewritten)
- `DashboardScaffold` = `Scaffold` + `IndexedStack` + Material-3 `NavigationBar`: **Home · Modules · Inbox · Account**, brand indicator, Inbox carries `Badge` unread count. Tab switch debounced (`_goTab`), Inbox refetched on entry.
- Shared `_ShellHeader` (private, replaces ad-hoc hero Container): navy gradient, r28 bottom, optional auto-back circle, greeting/role OR explicit title/subtitle, inbox bell w/ badge, sign-out, gold hairline. `user` is nullable so Inbox tab can render without a fake user.
- Home tab = header + `HomeOverview` + listTitle row w/ "Find" + module grid. Modules tab = header + `SvSearchField` + phase `SvFilterChips` + filtered grid + `SvEmptyState` on no match. Account tab = identity card (gradient initials avatar, role `SvStatusBadge`) + Session section + sign-out + tagline.
- `_ModuleGrid` extracted (shared by Home + Modules); `_ModuleCard` unchanged visuals.
- `NotificationsInboxScreen` split: screen = `SvScreenHeader` + `NotificationsInboxBody`. Body has `onChanged` callback for badge sync, and "Mark all read" moved from app-bar action into its own header row (works in both screen and tab context).

## Auth screens (premium pass)
- `login_screen.dart`: navy gradient bg, gold icon tile + gold hairline under wordmark, card gains "Welcome back" heading (NOT "Sign in" — would break `findsOneWidget`), email validator, password visibility toggle (`onFieldSubmitted` for enter-to-submit), `svSnack(error:)` on failure, demo credentials in a pill, controllers disposed.
- `register_screen.dart`: `SvScreenHeader` (title+subtitle) replaces plain AppBar, `SegmentedButton` role picker replaces dropdown (theme `ButtonStyle` w/ `WidgetStateProperty`), autofill hints, `next` text actions, password toggle + helper text, "I already have an account" → pop, `svSnack` on failure.

## Verification (this session)
- `flutter analyze lib` → **No issues found** — final run covers all 4 workstreams (3 agents reported errors fixed *by inspection* under a one-run rule; the lead re-ran analyze to genuinely verify each set: security/app/settings 0, fees/students 0 via full run, reports/communication 0, sync 0).
- `flutter test` → **22 passed / 9 skipped** — baseline preserved (run 3×, green after shell wiring, after messaging model change, and after full integration).
- `flutter build apk --debug` → ✓ built (177 s, 193 MB) `build/app/outputs/flutter-apk/app-debug.apk`.
- Disconnected at this point in the session; device `R8YL30E37XH` reconnected later and everything below was then installed + screenshot-verified (see "On-device bug-fix round").
- Regression caught & fixed mid-session: `_InboxTab` nested the inbox `ListView` inside the tab `ListView` → "Vertical viewport given unbounded height" ×11, failed widget_test. Fixed with `Column` + `Expanded` (header non-scrolling, body bounded).
- Installed on device R8YL30E37XH 3× this session (final build carries the reports-dropdown + banner fixes); all verifications green — see the on-device round below.

## On-device bug-fix round (this session, later phase)

Four bugs surfaced during hands-on verification — **two found by the user's own walkthrough** — all fixed, gated (`flutter analyze lib` → No issues; `flutter test` → 22 passed / 9 skipped), rebuilt, reinstalled and screenshot-verified on `R8YL30E37XH`:

1. **LockScreen Overlay crash + fake overflow** (`lib/features/security/app_lock_gate.dart`) — the gate sits *above* the Navigator, so `Overlay.maybeOf(context)` was null and every `Tooltip` on LockScreen (PIN keys, biometric button, delete) threw `debugCheckHasOverlay` → red screen; the injected error widget inside the header's unbounded `FittedBox` chain then painted as "BOTTOM OVERFLOWED BY 99560 PIXELS". Fix: `_lockLayer` wraps the cover in its own `Overlay` when none exists; the entry is created once per lock cycle (`_lockEntry`/`_lockContent`, re-announced via `entry.markNeedsBuild()` — legal mid-build since the entry is a descendant of the building gate) and `remove()`d by `_releaseLockEntry()` on unlock/sign-out (unmount does **not** null `entry._overlay`; a stale one asserts in `insertAll`). ✅ Verified: clean navy/gold lock screen, greeting, biometric button, 6 PIN dots, keypad, Sign out — no red screen, no overflow.
2. **Staff sheet** (admin) — ✅ Verified: `helperText` renders below the Class field with no label collision; password field obscured (8 dots + eye toggle).
3. **Reports & Export Assessment dropdown** — "RIGHT OVERFLOWED BY 55 PIXELS" (found live by the user at 14:25). Same root cause as the earlier Marking fix: a non-expanded `DropdownButtonFormField` with a long "title · subject" label. Fixed in `reports_screen.dart` (Student **and** Assessment) and hardened 4 more dynamic-label dropdowns — `learning_profile_screen`, `report_card_screen`, `safety_gate_screen`, `student_editor_screen` (parent picker) — all `isExpanded: true` + `TextOverflow.ellipsis` + `maxLines: 1`. Sweep found no other long-label dropdowns (attendance "reason" is a TextField; class/date/topic/enum pickers are short). ✅ Verified: full "Fractions Quick Diagnostic · Mathematics" inside the field with the arrow in-row, no stripe.
4. **SyncStatusBanner behind the status bar** (`lib/core/sync/sync_status_banner.dart`) — the strip pinned to the top of the edge-to-edge body painted its label *behind* the clock/icons (observed offline at 14:42). Fix: `SafeArea(bottom: false)` wrap around the StreamBuilder (no-op while idle/empty). ✅ Verified offline: icons on white, amber banner fully below with ⚠ glyph + label.

### Device cleanup (R8YL30E37XH, done)
- **Session restored:** teacher (`efua.mensah@school.gh` / `teacher123`) — verified "Welcome, Ms. / Teacher" at 14:59. (The user had signed in as admin themselves mid-session; the admin round-trip was done from their session — staff sheet verified as admin.)
- **App lock re-enabled:** `flutter.solvanta.lockEnabled=true` via pull→edit→push (pulls the *live* prefs so the teacher session survives) using the only working write path — `am force-stop`, then `run-as com.example.solvanta tee /data/user/0/com.example.solvanta/shared_prefs/FlutterSharedPreferences.xml < file`. On-device readback confirms `lockEnabled=true`, `lockMethod=biometric`, `lockPin=123456` (both untouched).
- **Dev settings reverted:** `accelerometer_rotation=1`, `svc power stayon false`, `screen_off_timeout=30000`.
- **App lock runtime-verified on device (15:49):** cold start → lock cover **captured** — SOLVANTA + gold hairline, 🔒 "App locked", "Welcome back, Ms. Efua Mensah", 6 PIN dots, keypad, Sign out; no red screen, no overflow. `lockMethod` was temporarily pushed to `pin` so no auto-biometric path could dismiss the cover before a +4 s capture, then restored — readback confirms `lockEnabled=true`, `lockMethod=biometric`, `lockPin=123456`, session `USR-TCH-001`. Earlier "no cover" readings were the user (actively holding the phone) dismissing it between capture windows — confirmed by the new host test below and the Settings toggle rendering ON.
- Gotchas for next time: `input tap` collides when the user is actively touching the device (screenshot before *every* tap) and goes **off-screen after the user re-enables auto-rotate** (landscape = 1600×720 — check `dumpsys window` orientation before tapping); with the panel off, `screencap` can return the *last surface* — a status-bar clock that doesn't match `shell date` means the frame is stale; a mid-field tap places the text cursor mid-string so `DEL` loops only clear text *before* it (use `keyevent 123` MOVE_END first); with Gboard open the login card shifts up ~150 px (email y≈705, password y≈826, Sign in only at (360,1112) after dismiss); `settings get system accelerometer_rotation` came back `1` mid-pass (user re-toggled it).

## Important Details (environment)
- Flutter 3.47.4 / Dart 3.13.3; `InkSparkle`, `TweenAnimationBuilder`, `withValues`, `WidgetStateProperty`, `SegmentedButton` available.
- Tool PATH: everything via `export PATH="$PATH:/mnt/devdrive/DevTools/flutter/bin"`. Android env: `export ANDROID_HOME=/mnt/devdrive/DevTools/android-sdk ANDROID_SDK_ROOT=/mnt/devdrive/DevTools/android-sdk`.
- NEVER `flutter install` without a fresh `flutter build apk --debug` (install uses existing APK).
- Device `R8YL30E37XH` (SM-A075F, 720x1600 @ density 3), adb at `/mnt/devdrive/DevTools/android-sdk/platform-tools/adb`.
- Backend still DOWN and unrebuildable (Go toolchain missing). Login/currentUser work offline via LocalStore seed.
- ON-DEVICE LOGIN BYPASS: `am force-stop` app SEEDED first (launch ≥8s), then `adb push` an edited `shared_prefs/FlutterSharedPreferences.xml` (key `flutter.solvanta.session_user_id` = `USR-TCH-001`) into `/data/data/com.example.solvanta/shared_prefs/` via `adb push /data/local/tmp/prefs.xml && run-as com.example.solvanta cp`. Teacher seed: `efua.mensah@school.gh` / `teacher123`, id `USR-TCH-001`.
- Box memory-constrained (3.4GB): kill leftover Gradle daemon before `flutter test` (OOM risk). NOTE: `pkill -f GradleDaemon` in the SAME shell command as the test silently swallows the whole command (pattern matches own argv) — run it as a separate call.
- Repo is not dart-format-canonical — match surrounding style; recurring paren-bug: wrapping `Card(` with `SvEntrance`+`SvPressScale` needs TWO extra `),` before the `);`. Gate every change on `flutter analyze lib` + `flutter test` (22 passed / 9 skipped).
- Dev-setting aids all reverted at session end: `svc power stayon false`, `screen_off_timeout 30000` (device default; the pre-session original was never recorded — 1800000 was ours), `accelerometer_rotation 1`.
- ModulePhase assignments locked: teacher Check-in (dashboard line 115) + Safety Gate (118) → beta; AI Question Generator → latest teacher (127) / admin (67) / staff (217); rest live.
- Brand tokens: `AppTheme.brand/navy900 #1B3B6F`, `brandLight/navy700 #2E5C9A`, `gold #E3A008`, ramp navy500 `#47719C` / navy400 `#5F86AE` / navy300 `#7E93B8` / navy200 `#9FB0CD` / navy100 `#DCE4EF` / navy50 `#F1F5FA`, bg `0xFFF9FAFB`. `AppColors.info/success/danger/warning/notAttempted/muted` exist (NOT on AppTheme); `SvStatusBadge` lives in ui_kit.dart.

## Shared UI kit (lib/core/ui/ui_kit.dart)
- `SvScreenHeader` — gradient header `implements PreferredSizeWidget`; fixed height 96/114 (title/±subtitle); auto back-circle, optional `actions`, `subtitle`. Matches dashboard hero radius (28).
- `SvFilterChips` + `SvFilterOption` — pill chips; selected = brand fill + white text.
- `SvSearchField` — rounded search input, brand prefix icon, clear suffix.
- `SvAvatarTile` — list card: gradient avatar (initials/icon), title, optional `meta`, `chip`/`trailing`, chevron when onTap.
- `svStatus(label, icon, color)` → SvStatusBadge.
- `SvSectionTitle` — gold accent bar + w800 15 title.
- `SvLoading` / `SvErrorState` / `SvEmptyState` / `SvEntrance` / `SvPressScale` / `SvAnimatedNumber` / `svSnack`.
- Theme: CardThemeData elevation 1.2 with ink.18 shadow, surfaceTint transparent, radius 18.

## On-device role verification (this session, evening ~21:46–22:44)

User directive "test the parent and the student side" — **both legs PASS**, screenshot-verified:

### Parent (`ama.owusu@school.gh` / `parent123`) — 5 screens
- **Home**: "Welcome, Ama / Parent / Guardian", parent KPIs (1 Child 👁 / 0 Unread), "All caught up" ✓ state, "My children" framing (role-adaptive, not "My teaching day"), 6 tiles (Arrival/Departure, Results & Reports, Attendance, Teacher Feedback, Announcements, My Fees).
- **My Fees**: header "Fees & Payments / Kojo Owusu" (child-scoped), Billed/Paid/Balance 2,350/2,350/**0** with line items summing correctly (1,550+450+200+150=2,350), invoice INV-2026T1-STU-001 "✓ Paid" chip (glyph+label), Pay CTA correctly hidden at zero balance.
- **Messages list**: thread under child name (KO avatar), teacher attendance note preview.
- **Thread**: "Kojo Owusu — Ms. Efua Mensah" header, navy right-aligned parent bubble with "11 Sep · 7:40 pm ✓✓ Read" (glyph+label ✓ brand rule), composer.

### Student (`kojo.owusu@school.gh` / `student123`) — 5 screens
- **Home**: "Welcome, Kojo / Student", student KPIs (2 Due / 0 Updates), assignment + results prompts, "My learning" tiles, 4-tab student nav.
- **Home grid (scrolled)**: 9 tiles — My Profile, My Results, Announcements, Academic Calendar, Assignments, Study Hub, BECE/WASSCE, My Fees, **My ID (Digital student ID card)**.
- **Student ID / QR (`StudentQrScreen`)** — *never previously verified*: KO avatar + gold ring, gold verified badge, navy-on-white QR rendered, Admission S-2023-001 / Class JHS2A / school, "SOLVANTA · Scan at the gate to verify" footer, Share ID card (PNG) + Scan mode, privacy copy. No overflow, palette exact.
- **My Fees**: identical child data as parent view (role-consistent).
- **Modules**: header "9 tools · student" (vs teacher's 17), student-framed search "Search my learning…", chip filters.

### Restore (done, verified)
- Teacher session back: "Welcome, Ms. Efua / Teacher" + full KPIs.
- Theme → **System** (Settings segment now selected; device is in *system dark mode* (user's evening setting) so the app renders dark — final home + Settings captured in dark, no overflow; app themeMode=System ✓).
- Settings shows **App lock ON + Biometric** (lockEnabled/lockMethod intact; PIN 123456 proven live tonight).
- adb: `stay_on_while_plugged_in=0`, `screen_off_timeout=30000`, `accessibility_enabled=1` (user had already restored), `accelerometer_rotation=1`.
- Input wedge **resolved without reboot** (reboot never fired — command aborted); injection recovered on its own over the hours; all taps/swipes/keyevents/text worked from ~21:46 on, with the usual ~10–30% single-event loss (retry pattern).

### New gotchas (evening round)
- **Verify every credential edit with a cap before signing in**: a lost `keyevent 67` run silently leaves junk (observed `studstudent123`, `teacher123student123` — clears only text *before* the cursor unless `123` lands; when in doubt `123` + DEL×30 then retype and re-read).
- **Anything can steal the foreground mid-batch** (Gmail opened mid-login-dance once — user's notification/mail); check `mCurrentFocus` after each batch and never re-target blind; field coords only valid while *our* app holds focus.
- Login screen **prefills the last-used account** (email + password + demo pill) — after logout, check the pill before assuming which dance to run.
- **Black screencap while `BiometricPromptRoot` has focus** (panel awake per dumpsys) — cancel with `keyevent 4` to return to the app; a transient yellow-green screen border overlay appeared during that episode and cleared on its own.
- Cold start with an active session now reliably shows the biometric prompt then the lock keypad (lock engages even from launcher cold starts when a session exists).
- Session timeline gaps of 5–11 min appeared between captures — reads/user interaction take longer than they feel; clock checks in every cap remain the staleness test.

## Next Move (when user continues)
1. ~~Deferred lock screenshot~~ **DONE** — cover captured on device (15:49) + new host regression `test/lock_gate_test.dart` (proves `lockEnabled=true` → `LockScreen` on cold start through the real `SolvantaApp` wiring). Full suite now **23 passed / 9 skipped** (was 22 + 1 new).
1b. ~~Parent + student role tests~~ **DONE (evening round)** — parent 5 screens, student 5 screens (incl. the previously never-verified Student ID/QR), device restored to teacher + System theme + all dev settings reverted (see section above).
1c. Still-untested on device (only if user asks): global search flow, the 4 hardened dropdowns (learning_profile/report_card/safety_gate/student_editor), online backlog banner, PDF export, admin Fees + Learning-Profile trip.
2. Suggested follow-ups reported by agents: hash the PIN (needs a `v2` migration from the current plain-text `shared_prefs`), register a real `POST /api/payments` + `payment.record` replay handler once a backend exists, transcript template needs a term-history source, on-device TalkBack pass, BACK-from-biometric-prompt exits the app (known accepted omission — the gate's cover is a Stack, not a route).
3. Optional micro-polish: header subtitle counts, KPI card upgrade, avatar tiles on announcements/calendar/prep/study_hub/learning_profile.
4. Dev-setting revert: **done** (stayon false, timeout 30000, auto-rotate restored — see "Device cleanup").

## Relevant Files
- lib/core/theme/app_theme.dart — navy ramp tokens + nav/dialog/sheet themes.
- lib/features/home/widgets/dashboard_scaffold.dart — Navbar shell, 4 tabs, `_ShellHeader`, `_ModuleGrid`, `_AccountTab`.
- lib/features/notifications/notifications_inbox_screen.dart — split into screen + `NotificationsInboxBody(onChanged:)`.
- lib/features/auth/login_screen.dart, register_screen.dart — premium pass.
- lib/features/timetable/timetable_screen.dart, lib/features/analytics/analytics_screen.dart, lib/features/resources/resources_screen.dart, lib/core/models/resource.dart — ramp tokenisation.
- 30 files — grey→token sweep (see git-free list in This session).
- test/widget_test.dart — login→dashboard guard (must keep exactly one 'Sign in').
- test/lock_gate_test.dart — app-lock engage regression (added after the on-device lock verification; suite now 23 passed / 9 skipped).
- build/app/outputs/flutter-apk/app-debug.apk — fresh build.