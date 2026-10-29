import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/attendance/attendance_screen.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/home/dashboards.dart';
import 'package:solvanta/features/students/student_profile_screen.dart';

/// The quick search (Ctrl+K) and pinned menu items.
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

Future<void> _home(WidgetTester tester, String email, String password, double width) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final user = await tester.runAsync(() => AuthRepository().login(email: email, password: password));
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: dashboardFor(user!)));
  await _settle(tester);
}

Finder get _paletteField => find.byWidgetPredicate(
    (w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Jump to'));

void main() {
  testWidgets('staff jump to a page or a student from the quick search', (tester) async {
    await _home(tester, 'efua.mensah@school.gh', 'teacher123', 1440);
    await tester.tap(find.byTooltip('Search (Ctrl+K)'));
    await _settle(tester);
    expect(_paletteField, findsOneWidget);

    // A page: Enter opens the first match beside the sidebar.
    await tester.enterText(_paletteField, 'attend');
    await tester.pump();
    expect(find.text('MENU'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(_paletteField, findsNothing);
    expect(find.byType(AttendanceScreen), findsOneWidget);
    expect(find.text('SOLVANTA'), findsOneWidget);

    // A student, chosen with the arrow keys.
    await tester.tap(find.byTooltip('Search (Ctrl+K)'));
    await _settle(tester);
    await tester.enterText(_paletteField, 'kojo');
    await tester.pump();
    expect(find.text('STUDENTS'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Kojo Owusu'), findsOneWidget);
    // "kojo" matches no page, so the student is first; Enter opens it.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(find.byType(StudentProfileScreen), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);

    // The arrow keys move the choice: down once is the full-search hand-off.
    await tester.tap(find.byTooltip('Search (Ctrl+K)'));
    await _settle(tester);
    await tester.enterText(_paletteField, 'kojo');
    await tester.pump();
    // Three presses with no frame between them: down, down, up.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles.indexWhere((t) => t.selected), 1);
    expect(_uiError(tester), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a parent\'s quick search finds pages, not other pupils', (tester) async {
    await _home(tester, 'ama.owusu@school.gh', 'parent123', 390);
    await tester.tap(find.byTooltip('Search').first);
    await _settle(tester);
    await tester.enterText(_paletteField, 'akosua');
    await tester.pump();
    expect(find.text('STUDENTS'), findsNothing);
    expect(find.descendant(of: find.byType(ListTile), matching: find.textContaining('akosua')), findsOneWidget,
        reason: 'only the full-search hand-off');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(_paletteField, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pin a page with the hover star; it stays pinned', (tester) async {
    await _home(tester, 'efua.mensah@school.gh', 'teacher123', 1440);
    await tester.enterText(find.byType(TextField).first, 'mark w');
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Mark Work')));
    await tester.pump();
    await tester.tap(find.byTooltip('Pin Mark Work to the top'));
    await _settle(tester);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    expect(find.text('PINNED'), findsOneWidget);
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getStringList('solvanta.nav.USR-TCH-001.pinned'), ['Mark Work']);

    // Unpin from the pinned copy.
    await mouse.moveTo(tester.getCenter(find.text('Mark Work').first));
    await tester.pump();
    await tester.tap(find.byTooltip('Unpin Mark Work').first);
    await _settle(tester);
    expect(find.text('PINNED'), findsNothing);
    expect(_uiError(tester), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('on a phone a long press pins', (tester) async {
    await _home(tester, 'efua.mensah@school.gh', 'teacher123', 390);
    await tester.tap(find.byTooltip('Menu').first);
    await _settle(tester);
    await tester.longPress(find.descendant(of: find.byType(Drawer), matching: find.text('Take Attendance')));
    await _settle(tester);
    expect(find.text('PINNED'), findsOneWidget);
    expect(find.text('Take Attendance pinned to the top of the menu'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
