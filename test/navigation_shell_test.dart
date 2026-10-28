import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/home/dashboards.dart';
import 'package:solvanta/features/marking/marking_dashboard_screen.dart';

/// The app shell's menu: a sidebar that loads modules in place on large
/// screens, a hamburger drawer that opens them as screens on small ones.
Future<void> _settle(WidgetTester tester) async {
  // Entrance animations and spinners never settle; step real and fake time.
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Object? _uiError(WidgetTester tester) {
  for (var e = tester.takeException(); e != null; e = tester.takeException()) {
    if (e is! MissingPluginException) return e;
  }
  return null;
}

Future<void> _teacherAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final user = await tester.runAsync(
      () => AuthRepository().login(email: 'efua.mensah@school.gh', password: 'teacher123'));
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: dashboardFor(user!)));
  await _settle(tester);
}

void main() {
  testWidgets('desktop: grouped sidebar, modules load beside it', (tester) async {
    await _teacherAt(tester, 1440);
    expect(_uiError(tester), isNull);
    expect(find.text('SOLVANTA'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.byTooltip('Account menu'), findsOneWidget);
    expect(find.text('PEOPLE'), findsOneWidget);
    expect(find.text('ATTENDANCE & SAFETY'), findsOneWidget);
    // No readiness badges anywhere.
    expect(find.text('Live'), findsNothing);
    expect(find.text('Beta'), findsNothing);

    // The menu search narrows the list to what matches.
    await tester.enterText(find.byType(TextField).first, 'mark');
    await tester.pump();
    expect(find.text('MARKING & INSIGHTS'), findsOneWidget);
    expect(find.text('Question Bank'), findsNothing);

    await tester.tap(find.text('Mark Work'));
    await _settle(tester);
    expect(_uiError(tester), isNull);
    expect(find.byType(MarkingDashboardScreen), findsOneWidget);
    expect(find.text('SOLVANTA'), findsOneWidget, reason: 'the sidebar stays');

    // Collapsing leaves icons only.
    await tester.tap(find.byTooltip('Collapse menu'));
    await _settle(tester);
    expect(find.text('SOLVANTA'), findsNothing);
    expect(find.byTooltip('Expand menu'), findsOneWidget);
    expect(_uiError(tester), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('phone: hamburger drawer opens a module as its own screen', (tester) async {
    await _teacherAt(tester, 390);
    expect(_uiError(tester), isNull);
    expect(find.text('SOLVANTA'), findsNothing, reason: 'the menu is hidden until asked for');

    await tester.tap(find.byTooltip('Menu').first);
    await _settle(tester);
    expect(find.text('SOLVANTA'), findsOneWidget);
    expect(find.text('PEOPLE'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'mark');
    await tester.pump();

    await tester.tap(find.text('Mark Work'));
    await _settle(tester);
    expect(_uiError(tester), isNull);
    expect(find.byType(MarkingDashboardScreen), findsOneWidget);
    expect(find.text('SOLVANTA'), findsNothing, reason: 'the drawer closed');

    // Back home, the module is offered again under "Jump back in".
    await tester.pageBack();
    await _settle(tester);
    expect(find.text('Jump back in'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Mark Work'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
