import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/attendance/attendance_screen.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/home/dashboards.dart';
import 'package:solvanta/features/home/widgets/dashboard_scaffold.dart';
import 'package:solvanta/features/marking/marking_dashboard_screen.dart';

/// Back, addresses and breadcrumbs for the sidebar layout.
Future<void> _settle(WidgetTester tester) async {
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

Future<void> _teacher(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final user = await tester.runAsync(
      () => AuthRepository().login(email: 'efua.mensah@school.gh', password: 'teacher123'));
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: dashboardFor(user!)));
  await _settle(tester);
}

/// Opens a module from the sidebar through its search box.
Future<void> _openFromMenu(WidgetTester tester, String label) async {
  // Lower case, so the search box's own text isn't a match for the label.
  await tester.enterText(find.byType(TextField).first, label.toLowerCase());
  await tester.pump();
  await tester.tap(find.text(label).first);
  await _settle(tester);
}

void main() {
  tearDown(() => pendingModuleSlug = null);

  test('module addresses are readable slugs', () {
    expect(moduleSlug('Take Attendance'), 'take-attendance');
    expect(moduleSlug('Arrival / Departure'), 'arrival-departure');
    expect(moduleSlug('Reports & Export'), 'reports-export');
  });

  testWidgets('Back returns through the modules opened, then home', (tester) async {
    await _teacher(tester, 1440);
    await _openFromMenu(tester, 'Mark Work');
    expect(find.byType(MarkingDashboardScreen), findsOneWidget);
    // Breadcrumb: Home › section › module.
    expect(find.text('Marking & Insights'), findsOneWidget);

    await _openFromMenu(tester, 'Take Attendance');
    expect(find.byType(AttendanceScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byType(MarkingDashboardScreen), findsOneWidget);
    expect(find.byType(AttendanceScreen), findsNothing);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('Welcome back, Efua'), findsOneWidget);
    expect(_uiError(tester), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Back closes a page opened inside a module first', (tester) async {
    await _teacher(tester, 1440);
    await _openFromMenu(tester, 'Mark Work');
    final inside = tester.element(find.byType(MarkingDashboardScreen));
    Navigator.of(inside).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Inner page'))));
    await _settle(tester);
    expect(find.text('Inner page'), findsOneWidget);
    expect(find.text('SOLVANTA'), findsOneWidget, reason: 'inner pages stay beside the sidebar');

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('Inner page'), findsNothing);
    expect(find.byType(MarkingDashboardScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an address naming a module opens it beside the sidebar', (tester) async {
    pendingModuleSlug = 'take-attendance';
    await _teacher(tester, 1440);
    expect(find.byType(AttendanceScreen), findsOneWidget);
    expect(find.text('SOLVANTA'), findsOneWidget);
    expect(pendingModuleSlug, isNull, reason: 'used once');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('on a phone the module opens as its own screen', (tester) async {
    pendingModuleSlug = 'take-attendance';
    await _teacher(tester, 390);
    expect(find.byType(AttendanceScreen), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);
    expect(find.byType(AttendanceScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an unknown address is ignored', (tester) async {
    pendingModuleSlug = 'no-such-module';
    await _teacher(tester, 1440);
    expect(_uiError(tester), isNull);
    expect(find.text('Welcome back, Efua'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
