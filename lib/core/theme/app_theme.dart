import 'package:flutter/material.dart';

/// SOLVANTA brand system (60% neutral / 30% navy / 10% gold + semantic).
/// See the brand spec: nav/headers/buttons in deep navy; gold used sparingly
/// (~10%) for highlights + progress gains; marking states always paired with
/// a glyph — never color alone.
class AppTheme {
  /// Brand primary — deep navy-indigo. Constant in both brightnesses: it is
  /// the brand DNA used for gradients, solid fills and the white-on-navy
  /// surfaces that must not change with the theme.
  static const brand = Color(0xFF1B3B6F);

  /// Primary light — hover states, secondary surfaces, chart ramp top.
  static const brandLight = Color(0xFF2E5C9A);

  /// Accent gold — highlights, progress gains (sparingly).
  static const gold = Color(0xFFE3A008);

  /// Backwards-compatible alias (used across prep/study screens for highlights).
  static const accent = gold;

  // ---------------------------------------------------------------------
  // Single navy ramp. Every chart, distribution bar, category tint and
  // decorative fill draws from these steps (deep → light). Brand rule:
  // learning-gap / grade views use this ramp only — never traffic lights.
  // ---------------------------------------------------------------------

  /// Ramp 900 — equals [brand]. Use where emphasis matters most.
  static const navy900 = brand;

  /// Ramp 700 — equals [brandLight].
  static const navy700 = brandLight;

  /// Ramp 500.
  static const navy500 = Color(0xFF47719C);

  /// Ramp 400.
  static const navy400 = Color(0xFF5F86AE);

  /// Ramp 300.
  static const navy300 = Color(0xFF7E93B8);

  /// Ramp 200.
  static const navy200 = Color(0xFF9FB0CD);

  /// Ramp 100 — hairline tint for subtle navy surfaces.
  static const navy100 = Color(0xFFDCE4EF);

  /// Ramp 50 — page-level navy wash (hero underlays, empty states).
  static const navy50 = Color(0xFFF1F5FA);

  /// Ordered deep → light. Index 0 for the strongest series/grade.
  static const navyRamp = [
    navy900,
    navy700,
    navy500,
    navy400,
    navy300,
    navy200,
  ];

  /// Light (default) appearance.
  static ThemeData light() => _build(Brightness.light);

  /// Dark appearance — same brand, inverted neutrals and lifted semantic
  /// foregrounds so every state still clears WCAG AA on the dark surface.
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final c = AppPalette.forBrightness(brightness);
    final isDark = brightness == Brightness.dark;

    final scheme = ColorScheme.fromSeed(
      seedColor: brand,
      primary: brand,
      secondary: gold,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      splashFactory: InkSparkle.splashFactory,
      scaffoldBackgroundColor: c.background,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: c.ink,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: c.ink),
      ),
      cardTheme: CardThemeData(
        elevation: isDark ? 0 : 1.2,
        // Dark cards are separated by contrast, not by a light halo.
        shadowColor: isDark
            ? Colors.black.withValues(alpha: .4)
            : c.ink.withValues(alpha: .18),
        surfaceTintColor: Colors.transparent,
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        floatingLabelStyle: TextStyle(color: c.brandFg),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          // Lifted off the navy so the focus ring stays visible on dark.
          borderSide: BorderSide(color: c.brandFg, width: 1.8),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0.1,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: brand,
          foregroundColor: Colors.white,
          elevation: 0,
          shadowColor: brand.withValues(alpha: .35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.brandFg,
          side: BorderSide(color: c.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.brandFg,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.ink,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.brandFg,
        titleTextStyle:
            TextStyle(color: c.ink, fontWeight: FontWeight.w600),
        subtitleTextStyle: TextStyle(color: c.body),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF232B3D) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      chipTheme: const ChipThemeData(
        showCheckmark: false,
        labelStyle: TextStyle(fontWeight: FontWeight.w600),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.brandFg,
        linearTrackColor: c.border,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 66,
        indicatorColor: brand.withValues(alpha: isDark ? .28 : .10),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 23,
            color: selected ? c.brandFg : c.body,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            letterSpacing: .1,
            color: selected ? c.brandFg : c.body,
          );
        }),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        titleTextStyle: TextStyle(
          color: c.ink,
          fontSize: 17,
          fontWeight: FontWeight.w800,
          letterSpacing: -.2,
        ),
        contentTextStyle: TextStyle(
          color: c.body,
          fontSize: 14,
          height: 1.45,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values)
            platform: const _SolvantaPageTransitionBuilder(),
        },
      ),
    );
  }
}

/// The neutral + semantic values that change with brightness.
///
/// Brand constants (`AppTheme.brand`, the navy ramp, `AppTheme.gold`) live on
/// [AppTheme] and never change — they are the identity. Everything here is a
/// surface or a foreground whose contrast depends on the theme.
class AppPalette {
  const AppPalette({
    required this.ink,
    required this.body,
    required this.border,
    required this.background,
    required this.surface,
    required this.brandFg,
    required this.goldFg,
    required this.info,
    required this.successBg,
    required this.warningBg,
    required this.dangerBg,
    required this.infoBg,
    required this.correct,
    required this.needsReview,
    required this.incorrect,
    required this.notAttempted,
    required this.dangerSolid,
  });

  /// Headings, primary text.
  final Color ink;

  /// Secondary text.
  final Color body;

  /// Hairlines, dividers, input borders.
  final Color border;

  /// Page background.
  final Color background;

  /// Cards, sheets, dialogs, inputs.
  final Color surface;

  /// Brand navy when it acts as a *foreground* (icons, links, focus rings,
  /// selected nav). Deep navy is unreadable on a dark surface, so dark mode
  /// lifts it to a pale navy of the same hue.
  final Color brandFg;

  /// Accent gold when it acts as a *foreground* (small labels, markers).
  /// [AppTheme.gold] on white is only 2.3:1 — unreadable as text — so light
  /// mode uses a deep gold of the same hue (5.1:1 on white and on gold
  /// tints); dark mode lifts it, where the brand gold already passes.
  final Color goldFg;

  /// Informational foreground (the light-navy "info" accent).
  final Color info;

  // Tinted status backgrounds — always paired with a glyph, never alone.
  final Color successBg;
  final Color warningBg;
  final Color dangerBg;
  final Color infoBg;

  // Marking / status foregrounds, lifted in dark so they stay AA on their
  // own tinted backgrounds.
  final Color correct;
  final Color needsReview;
  final Color incorrect;
  final Color notAttempted;

  /// Solid danger background for surfaces that carry white text (e.g. the
  /// error SnackBar). Kept dark-on-white readable in *both* modes, unlike
  /// [incorrect] which is tuned for text-on-tint.
  final Color dangerSolid;

  static const light = AppPalette(
    ink: Color(0xFF101828),
    body: Color(0xFF475467),
    border: Color(0xFFD0D5DD),
    background: Color(0xFFF9FAFB),
    surface: Colors.white,
    brandFg: Color(0xFF1B3B6F),
    goldFg: Color(0xFF8A6100),
    info: Color(0xFF2E5C9A),
    successBg: Color(0xFFF1F7F5),
    warningBg: Color(0xFFFFF6E0),
    dangerBg: Color(0xFFFDECEC),
    infoBg: Color(0xFFEAF2FD),
    correct: Color(0xFF12805C),
    needsReview: Color(0xFFB45309),
    incorrect: Color(0xFFB42318),
    notAttempted: Color(0xFF667085),
    dangerSolid: Color(0xFFB42318),
  );

  static const dark = AppPalette(
    ink: Color(0xFFE9EDF5),
    body: Color(0xFFA6B1C4),
    border: Color(0xFF2B3345),
    background: Color(0xFF0E1424),
    surface: Color(0xFF161C2B),
    brandFg: Color(0xFF8FB3E0),
    goldFg: Color(0xFFF5C24B),
    info: Color(0xFF7FB0E8),
    successBg: Color(0xFF0F2A21),
    warningBg: Color(0xFF2A1F0D),
    dangerBg: Color(0xFF2C1310),
    infoBg: Color(0xFF101F3A),
    correct: Color(0xFF3DBE95),
    needsReview: Color(0xFFE9A23B),
    incorrect: Color(0xFFF2857A),
    notAttempted: Color(0xFF98A2B3),
    dangerSolid: Color(0xFF7A1810),
  );

  static AppPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// Semantic color palette shared across the app. Status is never conveyed
/// with color alone; use a `SvStatusBadge` (icon + label + color) instead.
///
/// Neutrals and semantic states are **getters** resolved against the active
/// [AppColors.brightness], so call sites never need a `BuildContext`. Brand
/// constants stay on [AppTheme].
class AppColors {
  /// Brightness the app is currently rendering with. Set once per theme
  /// change by the theme controller before the tree rebuilds.
  static Brightness brightness = Brightness.light;

  static bool get isDark => brightness == Brightness.dark;

  /// The palette matching [brightness].
  static AppPalette get palette => AppPalette.forBrightness(brightness);

  /// The palette matching an explicit [b] — used when building a
  /// [ThemeData], which must not depend on the globally active theme.
  static AppPalette paletteFor(Brightness b) => AppPalette.forBrightness(b);

  /// Applies a new brightness. Call before rebuilding the tree.
  static void setBrightness(Brightness b) => brightness = b;

  // ---------------------------------------------------------------------
  // Constants — brand DNA, identical in both brightnesses.
  // ---------------------------------------------------------------------

  /// Primary light (hover, secondary surfaces, chart ramp top).
  static const primaryLight = AppTheme.brandLight;

  /// Accent gold — highlights, progress gains.
  static const accent = AppTheme.gold;

  // ---------------------------------------------------------------------
  // Brand foreground — resolves per brightness.
  // ---------------------------------------------------------------------

  /// Foreground-ready brand primary (deep navy on light, pale navy on dark).
  static Color get brand => palette.brandFg;

  /// Backwards-compatible alias for the primary.
  static Color get primary => palette.brandFg;

  /// Primary light (hover, secondary surfaces, chart ramp top).
  static Color get info => palette.info;

  /// Accent gold as a *foreground* (text-sized labels, meaningful dots) —
  /// AA on white and on gold tints in both brightnesses. Use [AppTheme.gold]
  /// only for decorative hairlines and large glyphs.
  static Color get goldFg => palette.goldFg;

  // ---------------------------------------------------------------------
  // Marking / status states — always paired with a glyph.
  // ---------------------------------------------------------------------

  /// Marking state: Correct — always paired with a ✓ glyph.
  static Color get correct => palette.correct;

  /// Marking state: Needs review — always paired with a ⚠ glyph.
  static Color get needsReview => palette.needsReview;

  /// Marking state: Incorrect — always paired with a ✗ glyph.
  static Color get incorrect => palette.incorrect;

  /// Marking state: Not attempted — always paired with a ○ glyph.
  static Color get notAttempted => palette.notAttempted;

  /// Legacy semantic aliases (success/warning/danger now map to the marking
  /// states so any existing screen picks up the brand values automatically).
  static Color get success => palette.correct;
  static Color get successBg => palette.successBg;
  static Color get warning => palette.needsReview;
  static Color get warningBg => palette.warningBg;
  static Color get danger => palette.incorrect;
  static Color get dangerBg => palette.dangerBg;

  /// Solid danger surface carrying white text (error SnackBars).
  static Color get dangerSolid => palette.dangerSolid;

  static Color get infoBg => palette.infoBg;

  // Neutrals — structural only, never meaningful on their own.
  static Color get ink => palette.ink; // headings, primary text
  static Color get body => palette.body; // secondary text
  static Color get border => palette.border; // hairlines, dividers
  static Color get background => palette.background; // page background
  static Color get surface => palette.surface; // cards

  /// Brand navy read as a foreground — alias of [brandFg] semantics.
  static Color get brandFg => palette.brandFg;

  // Text aliases.
  static Color get text => ink;
  static Color get muted => body;
}

/// Apps push screens with gentle consistency: a short fade with a subtle
/// upward slide, on every platform. Subtle enough to feel native, smooth
/// enough to notice.
class _SolvantaPageTransitionBuilder extends PageTransitionsBuilder {
  const _SolvantaPageTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 0, end: 1).animate(curved),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .05),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Convert an ISO date (`2026-09-10`) or timestamp (`2026-09-11T08:15`,
/// `2026-09-21 10:30`) into a short, readable label for parents and
/// front-line staff.
String svFormatDate(String iso) {
  final s = iso.trim();
  if (s.isEmpty) return '';
  final datePart = s.contains('T')
      ? s.split('T').first
      : (s.contains(' ') ? s.split(' ').first : s);
  final d = DateTime.tryParse(datePart);
  if (d == null) return s;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final day = d.day.toString().padLeft(2, '0');
  final month = d.month >= 1 && d.month <= 12 ? months[d.month - 1] : '${d.month}';
  final year = d.year == DateTime.now().year ? '' : ' ${d.year}';
  return '$day $month$year';
}

String svFormatTime(String iso) {
  final s = iso.trim();
  if (s.isEmpty) return '';
  final timePart = s.contains('T')
      ? s.split('T').last
      : (s.contains(' ') ? s.split(' ').last : '');
  if (timePart.isEmpty ||
      !RegExp(r'^\d{1,2}:\d{2}').hasMatch(timePart)) {
    return svFormatDate(s);
  }
  final parts = timePart.split(':');
  var h = int.tryParse(parts[0]) ?? 0;
  final min = parts.length > 1 ? parts[1] : '00';
  final am = h < 12;
  if (h == 0) h = 12;
  if (h > 12) h -= 12;
  return '$h:$min ${am ? 'am' : 'pm'}';
}
