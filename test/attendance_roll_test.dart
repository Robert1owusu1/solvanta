import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/models/attendance.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/attendance/attendance_repository.dart';
import 'package:solvanta/features/attendance/attendance_screen.dart';
import 'package:solvanta/features/audit/audit_repository.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/students/students_repository.dart';

/// A roll that has been taken is not taken again by accident: it opens
/// read-only, and changing it is an explicit edit with a logged reason.
String _today() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

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

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: const AttendanceScreen()));
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a fresh roll can be taken', (tester) async {
    await tester.runAsync(() => AuthRepository().login(email: 'efua.mensah@school.gh', password: 'teacher123'));
    await _open(tester);
    expect(_uiError(tester), isNull);
    expect(find.text('Save attendance'), findsOneWidget);
    expect(find.text('Edit attendance'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a taken roll is read-only until edited, and an edit needs a reason', (tester) async {
    final today = _today();
    await tester.runAsync(() async {
      await AuthRepository().login(email: 'efua.mensah@school.gh', password: 'teacher123');
      final roll = (await StudentsRepository().all()).where((s) => s.classId == 'JHS2A');
      await AttendanceRepository()
          .saveDay('JHS2A', today, {for (final s in roll) s.id: AttendanceStatus.present});
    });
    await _open(tester);
    expect(_uiError(tester), isNull);

    expect(find.text('Attendance taken for $today.'), findsOneWidget);
    expect(find.text('Save attendance'), findsNothing, reason: 'nothing to retake');
    final absent = find.byTooltip('Absent').first;
    expect(tester.widget<IconButton>(find.ancestor(of: absent, matching: find.byType(IconButton)).first).onPressed,
        isNull, reason: 'marks are locked');

    // Edit: change one mark, save, give a reason.
    await tester.tap(find.text('Edit attendance'));
    await _settle(tester);
    expect(find.text('Save changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Absent').first);
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await _settle(tester);
    expect(find.text('Why change this roll?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Sent home sick before the first lesson');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save changes').last);
    await _settle(tester);
    expect(_uiError(tester), isNull);

    // Locked again, and the change is on record with its reason.
    expect(find.text('Attendance taken for $today.'), findsOneWidget);
    final audit = await tester.runAsync(() => AuditRepository().all());
    final entry = audit!.where((e) => e.action == 'attendance.correction').toList();
    expect(entry, hasLength(1));
    expect(entry.single.reason, 'Sent home sick before the first lesson');
    expect(entry.single.detail, contains('1 attendance record'));
    final records = await tester.runAsync(() => AttendanceRepository().forClassDate('JHS2A', today));
    expect(records!.where((r) => r.status == AttendanceStatus.absent), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
