import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/app.dart';
import 'package:solvanta/core/settings/app_settings.dart';
import 'package:solvanta/core/theme/app_theme.dart';

/// Switching to dark mode must repaint screens that are already open — the
/// home page sits under Settings when the switch is made, and its
/// `AppColors` text used to keep the light palette (dark text on dark).
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Color? _colourOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text).first).style?.color;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
        'solvanta.session_user_id': 'USR-TCH-001',
        'solvanta.themeMode': 'light',
      }));
  tearDown(() async {
    await AppSettings.instance.setThemeMode(ThemeMode.light);
    AppColors.setBrightness(Brightness.light);
  });

  testWidgets('the open home page takes the dark palette', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const SolvantaApp());
    await _frames(tester);
    for (var e = tester.takeException(); e != null; e = tester.takeException()) {
      if (e is! MissingPluginException) fail('$e');
    }
    const heading = 'My teaching day';
    expect(find.text(heading), findsWidgets);
    final light = AppColors.paletteFor(Brightness.light).ink;
    final dark = AppColors.paletteFor(Brightness.dark).ink;
    expect(_colourOf(tester, heading), light);

    await tester.runAsync(() => AppSettings.instance.setThemeMode(ThemeMode.dark));
    await _frames(tester);
    expect(_colourOf(tester, heading), dark, reason: 'the home page was repainted');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
