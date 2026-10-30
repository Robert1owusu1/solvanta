import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/models/parent_meeting.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/assessment/results_screen.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/reports/parent_meetings_repository.dart';
import 'package:solvanta/features/reports/parent_meetings_screen.dart';

Future<void> _open(
  WidgetTester tester,
  String email,
  String pw,
  Widget home,
) async {
  await tester.runAsync(
    () => AuthRepository().login(email: email, password: pw),
  );
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home));
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<ParentMeeting> _request(ParentMeetingsRepository repo) => repo.request(
  studentId: 'STU-001',
  classId: 'JHS2A',
  year: '2026/2027',
  term: 'Term 1',
  reason: 'Year average 41.2, below 45',
  requestedBy: 'Ms. Efua Mensah',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('one open meeting per pupil per term', () async {
    final repo = ParentMeetingsRepository();
    final first = await _request(repo);
    final again = await _request(repo);
    expect(again.id, first.id);
    await repo.save(
      first.copyWith(status: MeetingStatus.held, outcome: 'Done'),
    );
    final next = await _request(repo);
    expect(next.id, isNot(first.id)); // the last one was closed
  });

  testWidgets('staff see open meetings with their actions', (tester) async {
    await tester.runAsync(() => _request(ParentMeetingsRepository()));
    await _open(
      tester,
      'efua.mensah@school.gh',
      'teacher123',
      const ParentMeetingsScreen(),
    );
    expect(find.textContaining('Kojo Owusu'), findsOneWidget);
    expect(find.text('Book'), findsOneWidget);
    expect(find.textContaining('below 45'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a family sees a booked meeting, not a mere request', (
    tester,
  ) async {
    late ParentMeeting m;
    await tester.runAsync(
      () async => m = await _request(ParentMeetingsRepository()),
    );
    await _open(
      tester,
      'ama.owusu@school.gh',
      'parent123',
      const ResultsScreen(studentId: 'STU-001'),
    );
    expect(find.text('Meetings with the school'), findsNothing);

    await tester.runAsync(
      () => ParentMeetingsRepository().save(
        m.copyWith(
          status: MeetingStatus.scheduled,
          scheduledFor: '2026-12-04 10:00',
          place: 'Staff room',
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await _open(
      tester,
      'ama.owusu@school.gh',
      'parent123',
      const ResultsScreen(studentId: 'STU-001'),
    );
    expect(find.text('Meetings with the school'), findsOneWidget);
    expect(find.text('2026-12-04 10:00 · Staff room'), findsOneWidget);
  });
}
