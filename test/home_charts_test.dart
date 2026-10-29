import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/home/dashboards.dart';
import 'package:solvanta/features/home/widgets/home_charts.dart';

/// The home dashboard's charts, per role, on the seeded offline data.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
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

Future<void> _home(WidgetTester tester, String email, String password, double width,
    {Brightness brightness = Brightness.light, double height = 1100}) async {
  // On a phone the charts sit below the notices: a tall view keeps them built.
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  AppColors.setBrightness(brightness);
  addTearDown(() => AppColors.setBrightness(Brightness.light));
  final user = await tester.runAsync(() => AuthRepository().login(email: email, password: password));
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
    home: dashboardFor(user!),
  ));
  await _settle(tester);
}

void main() {
  testWidgets('leaders see attendance, results and grade spread for the school', (tester) async {
    await _home(tester, 'admin@solvanta.app', 'admin123', 1440);
    expect(_uiError(tester), isNull);
    expect(find.text('Attendance'), findsWidgets);
    expect(find.text('Average results'), findsOneWidget);
    expect(find.text('Grade spread'), findsOneWidget);
    expect(find.byType(LineChart), findsOneWidget);
    expect(find.byType(BarChart), findsNWidgets(2));
    expect(find.textContaining('Whole school'), findsWidgets);

    // Every chart has a table view of the same numbers.
    await tester.tap(find.byTooltip('Show as table').first);
    await tester.pump();
    expect(find.textContaining('% present ('), findsWidgets);
    expect(find.byType(LineChart), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a parent sees their child\'s results, not the school\'s spread', (tester) async {
    await _home(tester, 'ama.owusu@school.gh', 'parent123', 390, height: 2600);
    expect(_uiError(tester), isNull);
    expect(find.text('Results'), findsOneWidget);
    expect(find.text('Grade spread'), findsNothing);
    expect(find.textContaining('Your children'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('charts render in dark mode at phone width', (tester) async {
    await _home(tester, 'efua.mensah@school.gh', 'teacher123', 390, brightness: Brightness.dark, height: 2600);
    expect(_uiError(tester), isNull);
    expect(find.textContaining('Your class'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop: notices and upcoming sit beside the charts', (tester) async {
    await _home(tester, 'admin@solvanta.app', 'admin123', 1440);
    expect(_uiError(tester), isNull);
    expect(find.text('Important notices'), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('PTA meeting'), findsOneWidget);
    expect(find.text('View all notices'), findsOneWidget);
    expect(find.text('View full calendar'), findsOneWidget);
    // Beside, not below: the panels start level with the overview.
    expect(tester.getTopLeft(find.text('Important notices')).dx,
        greaterThan(tester.getTopLeft(find.text('Average results')).dx));

    // "View all notices" opens Announcements in place, beside the sidebar.
    await tester.tap(find.text('View all notices'));
    await _settle(tester);
    expect(_uiError(tester), isNull);
    expect(find.text('SOLVANTA'), findsOneWidget);
    expect(find.text('Important notices'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a teacher\'s charts cover their class only', (tester) async {
    await _home(tester, 'efua.mensah@school.gh', 'teacher123', 1440);
    expect(_uiError(tester), isNull);
    await tester.tap(find.byTooltip('Show as table').at(1));
    await tester.pump();
    // The seed's JHS2A papers: Fractions (89% and 22%) and English (100%).
    expect(find.textContaining('· 2 papers'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
