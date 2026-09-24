# SOLVANTA — Accessibility audit

Static audit of `lib/` (contrast computed from WCAG 2.1 relative luminance,
control semantics from source inspection). Screens delivered by the parallel
fees / reports / security workstreams are audited after integration.

**Verdict: 7 issues found and fixed this pass; all audited text now meets
WCAG 2.1 AA (4.5:1 small text, 3:1 for meaningful graphics).**

## Fixed

| # | Issue | Where | Before → After |
|---|-------|-------|----------------|
| 1 | "New" module pill used brand gold as 10px bold text on a 12%-gold tint | `ModulePhase.fg` (`latest`) | **2.06:1 FAIL** → 5.06:1 (`AppColors.goldFg #8A6100`) |
| 2 | Calendar "has assignments" marker — meaningful graphic on white | `academic_calendar_screen.dart` | **2.26:1 FAIL** (needs 3:1) → 5.54:1 |
| 3 | `SvStatusBadge` label (11px bold) on its own 12% tint | `ui_kit.dart` | Correct **4.20**, Needs review **4.25**, Not attempted **4.29** → 4.54 / 4.64 / 4.61 (tint `.12` → `.06`) |
| 4 | `successBg` too deep for `Correct #12805C` text | `app_theme.dart` | **4.43:1 FAIL** → 4.54:1 (`#EAF6EE` → `#F1F7F5`) |
| 5 | 7 icon-only buttons with no accessible name | assessment builder, calendar prev/next, school admin, resources, timetable, check-in, assignments | no name → `tooltip:` on each |
| 6 | Reduce motion only silenced skeletons — entrance slide/fade, press-scale and count-up still animated | `SvEntrance`, `SvPressScale`, `SvAnimatedNumber` | ignored → honours `AppSettings.motionOff` **and** the OS `disableAnimations` flag |
| 7 | Password fields had no autofill hint / keyboard `done` action; spinner and error state were silent to screen readers; shimmer blocks were exposed as empty nodes | login, register, `SvLoading`, `SvErrorState`, `SvSkeleton` | → `AutofillHints.password`/`newPassword` + `TextInputAction.done`; `semanticsLabel: 'Loading'`; error state is a `liveRegion`; skeleton blocks `ExcludeSemantics` |

New token introduced: **`AppColors.goldFg`** (light `#8A6100`, dark `#F5C24B`)
— accent gold as a *foreground*. `AppTheme.gold #E3A008` stays the decorative
brand accent (hairlines, large glyphs); it is 2.26:1 on white and must never
carry text.

## Verified compliant (light mode)

| Pair | Ratio | Grade |
|------|-------|-------|
| Ink `#101828` on white | 17.75 | AAA |
| Body `#475467` on white / on `#F9FAFB` | 7.69 / 7.36 | AAA |
| Info `#2E5C9A` on its tint | 5.63 | AA |
| Incorrect `#B42318` on `dangerBg` | 5.76 | AA |
| Needs review `#B45309` on `warningBg` | 4.67 | AA |
| White on brand `#1B3B6F` | 11.04 | AAA |
| Brand navy on surface | 10.57 | AAA |
| Dark: body `#A6B1C4` on surface `#161C2B` | ~7 | AAA |
| Dark: every marking state on its tint | 5.42 – 7.97 | AA+ |

Marking states keep the exact spec hexes (`#12805C` `#B45309` `#B42318`
`#667085`) — only their *backgrounds* were adjusted, never the state colour.

## Confirmed by inspection

- **Status never colour-alone**: `SvStatusBadge` = icon + label + colour;
  marking views pair ✓ ⚠ ✗ ○ glyphs.
- **Gold usage**: decorative only (hairlines, accent bars, one icon), so its
  low contrast on white is exempt — except the two meaningful uses above.
- **Touch targets**: Material `IconButton`/`FilledButton`/`ChoiceChip`
  (compact density ⇒ ≥44dp); list rows pad 14px around a 40px tile.
- **Semantics**: bottom nav wrapped (`container`, "Main navigation"), module
  and account rows labelled (`Open <module>` / `<title>. <subtitle>`), every
  icon-only control has a `tooltip`.
- **Text scaling**: `largeText` applies a `TextScaler` (×1.25, clamped 2.2)
  app-wide; headers use `maxLines` + `TextOverflow.ellipsis`.
- **Form order**: every field has a persistent `labelText`; login/register
  carry autofill hints and `next`/`done` keyboard actions.

## Follow-ups (not blocking)

- On-device TalkBack pass — static audit cannot verify focus order, live-region
  timing or swipe-gesture discoverability.
- PIN keypad semantics to be re-checked once the security workstream lands.
- `SvFilterChips` sits at the 44dp boundary with `VisualDensity.compact`;
  measure under large text and bump padding if it clips.
